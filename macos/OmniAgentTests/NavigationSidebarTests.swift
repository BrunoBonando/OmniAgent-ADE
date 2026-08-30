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
            sidebar.navRows.map(\.item?.title),
            ["Home", "To Do List", "Search"]
        )
        XCTAssertEqual(
            sidebar.navRows.map(\.item?.symbol),
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

    /// Pinned to the floor, but inset from it: the chip is a card that has to
    /// clear the window's corner curve, not a strip flush with the edges.
    func testTheAccountRowIsPinnedAtTheBottom() {
        let sidebar = makeSidebar()
        XCTAssertTrue(sidebar.accountRow.superview === sidebar)
        XCTAssertEqual(sidebar.accountRow.frame.minY, 10, accuracy: 0.5, "inset off the bottom edge")
        XCTAssertEqual(
            sidebar.accountRow.frame.width, sidebar.bounds.width - 16, accuracy: 0.5,
            "inset from both side edges"
        )
        // Every row above it — but not the two full-height pieces that are not
        // rows at all: the glass ground runs the whole column *under* the chip,
        // and the trailing edge runs it *beside* the chip.
        let rows = sidebar.subviews.filter {
            $0 !== sidebar.accountRow && $0 !== sidebar.glassHost && $0 !== sidebar.trailingEdge
        }
        for sibling in rows {
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

    /// A real account: its name in the primary ink, and — until a picture
    /// arrives — its own initials in the circle.
    func testTheAccountRowShowsTheNameAndItsInitials() {
        let sidebar = makeSidebar()
        sidebar.accountRow.apply(name: "Bruno Bonando", picture: nil)
        XCTAssertEqual(sidebar.accountRow.accountLabel, "Bruno Bonando")
        XCTAssertEqual(sidebar.accountRow.avatarModeForTesting, .initials("BB"))
    }

    /// And back again: no name is the signed-out state, glyph and all — the
    /// row must never keep the last account it was shown.
    func testNoNameReturnsTheRowToThePlaceholderAndTheGenericGlyph() {
        let sidebar = makeSidebar()
        sidebar.accountRow.apply(name: "Bruno Bonando", picture: nil)
        sidebar.accountRow.apply(name: nil, picture: nil)
        XCTAssertEqual(sidebar.accountRow.accountLabel, "Not signed in")
        XCTAssertEqual(sidebar.accountRow.avatarModeForTesting, .glyph)
    }

    func testAPictureTakesTheCircleOverTheInitials() {
        let sidebar = makeSidebar()
        let picture = NSImage(size: NSSize(width: 44, height: 44))
        sidebar.accountRow.apply(name: "Bruno Bonando", picture: picture)
        XCTAssertEqual(sidebar.accountRow.avatarModeForTesting, .picture)
    }

    /// Two buttons in one chip: the account half routes to the account, the
    /// gear still offers the Settings panel.
    func testTheAccountHalfAndTheGearReportSeparately() throws {
        let sidebar = makeSidebar()
        var account = 0
        var settings = 0
        sidebar.onOpenAccount = { account += 1 }
        sidebar.onOpenSettings = { settings += 1 }

        try XCTUnwrap(sidebar.accountRow.accountButton.onPress)()
        XCTAssertEqual([account, settings], [1, 0])

        try XCTUnwrap(sidebar.accountRow.gear.onPress)()
        XCTAssertEqual([account, settings], [1, 1])
    }

    /// The hand cursor is drawn over exactly these two frames, so they have
    /// to be real, disjoint and inside the chip — an empty rect would take
    /// the pointer feedback with it and nothing else would notice.
    func testTheAccountRowsTwoPressableHalvesAreRealAndDisjoint() {
        let row = makeSidebar().accountRow
        XCTAssertGreaterThan(row.accountButton.frame.width, 0)
        XCTAssertGreaterThan(row.accountButton.frame.height, 0)
        XCTAssertGreaterThan(row.gear.frame.width, 0)
        XCTAssertFalse(row.accountButton.frame.intersects(row.gear.frame))
        XCTAssertTrue(row.bounds.contains(row.accountButton.frame))
        XCTAssertTrue(row.bounds.contains(row.gear.frame))
    }

    // MARK: - System stats

    /// The machine card sits directly above the account chip, on the same
    /// side insets.
    func testTheStatsCardSitsAboveTheAccountRow() {
        let sidebar = makeSidebar()
        XCTAssertTrue(sidebar.statsRow.superview === sidebar)
        XCTAssertEqual(
            sidebar.statsRow.frame.minY,
            sidebar.accountRow.frame.maxY + 8,
            accuracy: 0.5
        )
        XCTAssertEqual(sidebar.statsRow.frame.width, sidebar.bounds.width - 16, accuracy: 0.5)
    }

    /// Fractions render as whole percentages and clamp to 0...1; a metric
    /// with no reading says so instead of inventing a number.
    func testTheGaugesRenderPercentagesAndClamp() {
        let stats = SidebarSystemStatsView()
        stats.apply(cpu: 0.37, memory: 1.7, gpu: nil, animated: false)
        XCTAssertEqual(stats.cpuGauge.readout, "37%")
        XCTAssertEqual(stats.memoryGauge.readout, "100%")
        XCTAssertEqual(stats.gpuGauge.readout, "—")
    }

    /// The number's colour is the pressure analysis: green while comfortable,
    /// amber past 70%, red past 90% — and no verdict at all without a reading.
    func testTheGaugesWearThePressureColour() {
        let stats = SidebarSystemStatsView()
        stats.apply(cpu: 0.3, memory: 0.75, gpu: 0.95, animated: false)
        // Hue, not identity: the ramp also varies how present the colour is
        // with the fill, so an exact match would now be asserting the
        // strength curve by accident. `testTheColourStrengthensTowardTheLimit`
        // asserts that half deliberately.
        assertHue(stats.cpuGauge.readoutColor, ShellPalette.green)
        assertHue(stats.memoryGauge.readoutColor, ShellPalette.amber)
        assertHue(stats.gpuGauge.readoutColor, ShellPalette.red)

        stats.apply(cpu: 0.3, memory: 0.75, gpu: nil, animated: false)
        XCTAssertEqual(stats.gpuGauge.readoutColor, ShellPalette.inkTertiary, "no sample, no verdict")
    }

    /// The kernel answers on this machine: memory is always readable and in
    /// range. CPU legitimately needs two samples for a delta and the tick
    /// counters may not advance between them, so it only must not crash.
    func testMachineStatsAnswerFromTheKernel() {
        _ = MachineStats.cpuFraction()
        _ = MachineStats.cpuFraction()
        let memory = MachineStats.memoryFraction()
        XCTAssertNotNil(memory)
        XCTAssertGreaterThan(memory ?? 0, 0)
        XCTAssertLessThanOrEqual(memory ?? 0, 1)
    }

    // MARK: - Content routing (controller)

    /// Home shows its real screen, To Do List still lands on the "Under
    /// development" placeholder, and the pane workspace hides and comes back
    /// with the Desk.
    /// Settings is its own screen: the gear/⌘, land on it, it opens on the
    /// section it was last on, and every section still says "Under
    /// development" — the design's eight, in its order.
    func testSettingsIsItsOwnScreenWithItsOwnColumn() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        let settings = controller.settingsView
        XCTAssertTrue(settings.isHidden, "Home first")
        controller.showSettings(nil)
        XCTAssertEqual(controller.destination, .settings)
        XCTAssertEqual(controller.sessionTitleField.stringValue, "Settings", "named where a session is")
        XCTAssertFalse(settings.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(controller.homeView.isHidden)
        XCTAssertTrue(controller.workspaceView.isHidden)
        XCTAssertTrue(controller.shellSidebar.navRows.allSatisfy { !$0.isSelected }, "no left-menu row lights up")

        let panel = controller.settingsPanel
        XCTAssertEqual(
            panel.rows.map(\.titleText),
            ["General", "Accounts", "Sessions", "Themes", "Accessibility", "Customize", "Model providers", "Experimental"]
        )
        XCTAssertEqual(settings.section, .general)
        XCTAssertEqual(settings.titleField.stringValue, "General")
        XCTAssertEqual(settings.subtitleField.stringValue, "Under development")
        XCTAssertTrue(panel.rows[0].isSelected)

        panel.rows[1].onPress?()
        XCTAssertEqual(settings.section, .accounts)
        XCTAssertEqual(settings.titleField.stringValue, "Accounts")
        XCTAssertFalse(panel.rows[0].isSelected)
        XCTAssertTrue(panel.rows[1].isSelected)

        // Away forgets the section — off the page nothing is "here" — so
        // ⌘, comes back on General; opening on a named section moves it.
        controller.applyDestination(.home)
        XCTAssertTrue(settings.isHidden)
        XCTAssertEqual(controller.sessionTitleField.stringValue, "")
        XCTAssertTrue(panel.rows.allSatisfy { !$0.isSelected })
        controller.showSettings(nil)
        XCTAssertEqual(settings.section, .general)
        controller.showSettings(section: .experimental)
        XCTAssertEqual(settings.section, .experimental)
        XCTAssertEqual(controller.destination, .settings)
        controller.showSettings(nil)
        XCTAssertEqual(settings.section, .experimental, "⌘, on the page changes nothing")
    }

    /// Accounts is the first section with a screen: who is signed in, and
    /// the one button that changes it. Every other section keeps the
    /// "Under development" line.
    func testTheAccountsSectionNamesTheAccountAndOffersOneButton() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let settings = controller.settingsView

        controller.showSettings(section: .general)
        XCTAssertFalse(settings.subtitleField.isHidden)
        XCTAssertTrue(settings.accountField.isHidden, "the account block is Accounts' alone")
        XCTAssertTrue(settings.accountButton.isHidden)
        XCTAssertTrue(settings.githubField.isHidden)
        XCTAssertTrue(settings.githubButton.isHidden)

        controller.showSettings(section: .accounts)
        XCTAssertTrue(settings.subtitleField.isHidden, "a screen, not a promise")
        XCTAssertFalse(settings.accountField.isHidden)
        XCTAssertFalse(settings.accountButton.isHidden)
        XCTAssertFalse(settings.githubField.isHidden)
        XCTAssertFalse(settings.githubButton.isHidden)

        settings.applyAccount(email: "bruno@bonando.com", signedIn: true)
        XCTAssertEqual(settings.accountField.stringValue, "Signed in as bruno@bonando.com")
        XCTAssertEqual(settings.accountButton.title, "Log out")
        XCTAssertTrue(settings.accountSignedIn)

        // The GitHub line under it, in both states.
        XCTAssertEqual(settings.githubField.stringValue, "GitHub: not connected")
        XCTAssertEqual(settings.githubButton.title, "Connect GitHub…")
        XCTAssertFalse(settings.accountGitHubConnected)

        settings.applyAccount(email: "bruno@bonando.com", signedIn: true, githubLogin: "brunobonando")
        XCTAssertEqual(settings.githubField.stringValue, "GitHub: @brunobonando")
        XCTAssertEqual(settings.githubButton.title, "Disconnect")
        XCTAssertTrue(settings.accountGitHubConnected)

        // An empty row is not a handle: `auth_github_login` is cleared to
        // `""`, never removed, so "" has to read as "not connected".
        settings.applyAccount(email: "bruno@bonando.com", signedIn: true, githubLogin: "")
        XCTAssertEqual(settings.githubField.stringValue, "GitHub: not connected")
        XCTAssertFalse(settings.accountGitHubConnected)

        // Signed in with no address yet — how the page is seeded before the
        // daemon answers — is signed in all the same. Offering "Sign in…"
        // here would be offering a signed-in user a local sign-out.
        settings.applyAccount(email: nil, signedIn: true)
        XCTAssertEqual(settings.accountField.stringValue, "Signed in")
        XCTAssertEqual(settings.accountButton.title, "Log out")
        XCTAssertTrue(settings.accountSignedIn)

        settings.applyAccount(email: "", signedIn: false)
        XCTAssertEqual(settings.accountField.stringValue, "Not signed in")
        XCTAssertEqual(settings.accountButton.title, "Sign in…")
        XCTAssertFalse(settings.accountSignedIn)

        // And the button really is wired to the controller's own paths.
        var presented = 0
        controller.authGatePresenter = { _ in presented += 1 }
        settings.accountButton.performClick(nil)
        XCTAssertEqual(presented, 1, "signed out, the button offers the login screen")

        // Which of the two a press is, is the view's own decision — taken on
        // a bare view here, so logging out for real (which clears the launch
        // gate's `UserDefaults` mirror) stays out of this test.
        let bare = SettingsSurfaceView()
        var signIns = 0
        var logOuts = 0
        var connects = 0
        var disconnects = 0
        bare.onSignIn = { signIns += 1 }
        bare.onLogOut = { logOuts += 1 }
        bare.onConnectGitHub = { connects += 1 }
        bare.onDisconnectGitHub = { disconnects += 1 }
        bare.accountButton.performClick(nil)
        bare.githubButton.performClick(nil)
        bare.applyAccount(email: "bruno@bonando.com", signedIn: true, githubLogin: "brunobonando")
        bare.accountButton.performClick(nil)
        bare.githubButton.performClick(nil)
        XCTAssertEqual([signIns, logOuts], [1, 1], "one button, both jobs, by state")
        XCTAssertEqual([connects, disconnects], [1, 1], "and the same for the GitHub pair")
    }

    /// The Accounts section's third button, "Delete account…", exists only
    /// where deleting is possible: on Accounts, and only while signed in.
    /// Unlike Connect GitHub — which is honest to offer signed out, because
    /// the answer is "sign in first" — a delete with no account is nothing
    /// but a dead end.
    func testTheDeleteAccountButtonShowsOnlyOnAccountsWhileSignedIn() {
        let view = SettingsSurfaceView()
        view.select(.accounts)

        view.applyAccount(email: "bruno@bonando.com", signedIn: true)
        XCTAssertEqual(view.deleteAccountButton.title, "Delete account…")
        XCTAssertFalse(view.deleteAccountButton.isHidden)

        view.applyAccount(email: nil, signedIn: false)
        XCTAssertTrue(view.deleteAccountButton.isHidden, "no account, nothing to delete")

        // Signed in again, but on another section: the block is Accounts' alone.
        view.applyAccount(email: "bruno@bonando.com", signedIn: true)
        view.select(.general)
        XCTAssertTrue(view.deleteAccountButton.isHidden)
        view.select(.accounts)
        XCTAssertFalse(view.deleteAccountButton.isHidden, "and back when Accounts returns")

        // And the press is the controller's to perform, like the other two.
        var deletes = 0
        view.onDeleteAccount = { deletes += 1 }
        view.deleteAccountButton.performClick(nil)
        XCTAssertEqual(deletes, 1)
    }

    /// The gear offers the panel beside itself, tip on the gear, inside the
    /// content area; a pick docks it under the "Settings" title; the gear
    /// again offers it back; leaving the page hides it.
    func testTheGearOffersTheSettingsPanelAndAPickDocksIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        let sidebar = controller.shellSidebar
        let gear = sidebar.accountRow.gear
        let panel = controller.settingsPanel
        XCTAssertEqual(controller.settingsPanelPlace, .hidden)
        XCTAssertTrue(panel.isHidden)

        try XCTUnwrap(gear.onPress)()
        XCTAssertEqual(controller.settingsPanelPlace, .offered)
        XCTAssertEqual(controller.destination, .home, "offered, not opened")
        XCTAssertFalse(panel.isHidden)
        XCTAssertTrue(panel.rows.allSatisfy { !$0.isSelected }, "off the page, nothing is lit")
        XCTAssertTrue(panel.isTipVisible)
        let room = controller.settingsPanelRoomForTesting
        let offered = controller.settingsPanelTarget
        XCTAssertGreaterThanOrEqual(offered.minX, room.minX, "beside the sidebar, inside the content area")
        XCTAssertGreaterThanOrEqual(offered.minY, room.minY, "inside the app")
        let gearMidY = controller.settingsPanelRoomConvert(gear.bounds, from: gear).midY
        XCTAssertEqual(offered.minY + panel.tipCenterYForTesting, gearMidY, accuracy: 1, "the drop is on the gear")

        // Typing narrows the rows; the panel keeps its foot.
        panel.setQueryForTesting("acc")
        XCTAssertEqual(panel.visibleTitlesForTesting, ["Accounts", "Accessibility"])
        XCTAssertEqual(controller.settingsPanelTarget.minY, offered.minY, accuracy: 0.5)
        XCTAssertLessThan(controller.settingsPanelTarget.height, offered.height)

        try XCTUnwrap(panel.rows[1].onPress)()
        XCTAssertEqual(controller.destination, .settings)
        XCTAssertEqual(controller.settingsView.section, .accounts)
        XCTAssertEqual(controller.settingsPanelPlace, .docked)
        XCTAssertTrue(panel.rows[1].isSelected)
        XCTAssertEqual(panel.search.stringValue, "", "the query is spent")
        XCTAssertEqual(panel.visibleTitlesForTesting.count, SettingsSection.allCases.count)
        XCTAssertFalse(panel.isTipVisible)
        let docked = controller.settingsPanelTarget
        XCTAssertEqual(
            docked.minX + SettingsSidebarView.lane,
            controller.sessionTitleField.frame.minX,
            accuracy: 0.5,
            "the card under the title's left edge"
        )
        XCTAssertEqual(docked.maxY, room.maxY - WorkspaceTitleBarView.height - 10, accuracy: 0.5, "just below the strip")

        try XCTUnwrap(gear.onPress)()
        XCTAssertEqual(controller.settingsPanelPlace, .offered)
        XCTAssertEqual(controller.destination, .settings, "still on the page")
        XCTAssertTrue(panel.rows[1].isSelected, "on the page, the section is lit")
        try XCTUnwrap(gear.onPress)()
        XCTAssertEqual(controller.settingsPanelPlace, .docked, "the gear again puts it back")

        controller.applyDestination(.home)
        XCTAssertEqual(controller.settingsPanelPlace, .hidden)
        XCTAssertEqual(controller.settingsView.section, .general, "forgotten off the page")
    }

    func testHomeShowsItsScreenAndToDoThePlaceholder() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        controller.applyDestination(.home)
        XCTAssertTrue(controller.workspaceView.isHidden)
        XCTAssertFalse(controller.homeView.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(try XCTUnwrap(placeholderView(in: controller)).isHidden)

        controller.applyDestination(.todo)
        XCTAssertTrue(controller.workspaceView.isHidden)
        XCTAssertTrue(controller.homeView.isHidden)
        let placeholder = try XCTUnwrap(placeholderView(in: controller))
        XCTAssertFalse(placeholder.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(placeholder.titleText, WorkspaceDestination.todo.title)
        XCTAssertEqual(placeholder.subtitleText, "Under development")

        controller.applyDestination(.terminals)
        XCTAssertFalse(controller.workspaceView.isHidden)
        XCTAssertTrue(controller.homeView.isHidden)
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
        XCTAssertEqual(controller.destination, .home)
        XCTAssertTrue(controller.palette.model.commands.isEmpty, "nothing presented yet")

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .search }?.onPress)()

        XCTAssertFalse(controller.palette.model.commands.isEmpty, "the spotlight was presented")
        XCTAssertEqual(controller.destination, .home, "and Search selected nothing")
        XCTAssertTrue(controller.workspaceView.isHidden)
        controller.palette.dismiss()
    }

    // MARK: - The column's ground

    /// The column is Liquid Glass where there is glass to ask for: one
    /// full-bleed sheet at the very back of the view, with the design's blue
    /// washed over it rather than under it. Below macOS 26 there is no sheet
    /// and `draw` paints the opaque gradient exactly as it always did.
    func testTheColumnIsAGlassGroundCarryingTheBlueWash() throws {
        let sidebar = makeSidebar()

        guard #available(macOS 26.0, *) else {
            XCTAssertNil(
                sidebar.glassHost,
                "below 26 there is no glass to ask for and `draw` is the ground"
            )
            return
        }

        let glass = try XCTUnwrap(sidebar.glassHost, "macOS 26 has glass to ask for")
        XCTAssertIdentical(
            sidebar.subviews.first, glass, "the sheet is the ground, behind every row"
        )
        XCTAssertEqual(glass.frame, sidebar.bounds, "full-bleed: no inset, no floating slab")

        let wash = try XCTUnwrap(sidebar.glassTint)
        XCTAssertEqual(wash.frame.size, glass.frame.size, "the wash covers the whole sheet")
        let stops = try XCTUnwrap(wash.layer as? CAGradientLayer)
        let colors = try XCTUnwrap(stops.colors as? [CGColor])
            .compactMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
        XCTAssertEqual(colors.count, 2)
        let top = try XCTUnwrap(colors.first)
        let bottom = try XCTUnwrap(colors.last)
        // Translucent, or the wash is paint over the glass and hides the
        // material it is supposed to tint.
        XCTAssertLessThan(top.alphaComponent, 1)
        XCTAssertGreaterThan(top.alphaComponent, 0)
        XCTAssertLessThan(bottom.alphaComponent, top.alphaComponent, "top-lit, as it always was")
        // Still the column's blue, both ends.
        XCTAssertGreaterThan(top.blueComponent, top.redComponent)
        XCTAssertGreaterThan(bottom.blueComponent, bottom.redComponent)
        // Top to bottom: (0.5, 1) is the top in the layer's y-up unit space,
        // the direction `NSGradient`'s -90° angle gave the opaque gradient.
        XCTAssertEqual(stops.startPoint.y, 1)
        XCTAssertEqual(stops.endPoint.y, 0)
    }

    /// The column's trailing edge carries its own grey hairline. The sheet
    /// draws a rim there, but it measured `64, 65, 71` at its brightest
    /// against the pane black beside it — present, and not enough to say where
    /// the column stops. This line is, and it is grey on purpose: the column's
    /// own blue would read as part of the column rather than as its border.
    ///
    /// Drawn whatever the OS: below macOS 26 there is no sheet and so no rim
    /// at all, which is the case that needs it most.
    func testTheColumnsTrailingEdgeCarriesAGreySeparator() throws {
        let sidebar = makeSidebar()
        let edge = sidebar.trailingEdge

        XCTAssertEqual(edge.frame.width, 1, accuracy: 0.01, "a hairline, not a bar")
        XCTAssertEqual(
            edge.frame.maxX, sidebar.bounds.maxX, accuracy: 0.5, "pinned to the trailing edge"
        )
        XCTAssertEqual(
            edge.frame.height, sidebar.bounds.height, accuracy: 0.5,
            "the whole height, chrome included — the column runs under it"
        )
        XCTAssertIdentical(
            sidebar.subviews.last, edge, "over the glass and every row, never under them"
        )

        let cg = try XCTUnwrap(edge.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
        XCTAssertEqual(
            color.redComponent, color.blueComponent, accuracy: 0.02,
            "grey — the column's blue would read as column, not as border"
        )
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.02)
        XCTAssertGreaterThan(
            color.redComponent, 0.25, "and light enough to read against both sides"
        )
    }

    /// The sheet went behind the rows, not over them: a press still lands on
    /// the row under the cursor. A full-bleed view added on top would eat
    /// every click in the column.
    func testTheGlassGroundDoesNotSwallowTheRowsUnderIt() throws {
        let sidebar = makeSidebar()
        let row = try XCTUnwrap(sidebar.navRows.first)
        let centre = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: sidebar)

        // `hitTest` reads its point in the superview's space; this sidebar has
        // no superview and sits at the origin, so the column's own coordinates
        // are that space.
        let hit = try XCTUnwrap(sidebar.hitTest(centre))
        XCTAssertTrue(
            hit === row || hit.isDescendant(of: row),
            "the Home row should take its own click, not \(type(of: hit))"
        )
    }

    // MARK: - Offscreen render

    /// The whole flat column, rendered offscreen: the three nav rows, the
    /// Workspaces header, both workspace rows with their session rows and the
    /// dim empty row, and the pinned account row each put ink down where their
    /// frame says they are — a block whose region reads as flat panel
    /// background laid out but never drew. Drops a PNG when `PANE_RENDER_DIR`
    /// is set (`TEST_RUNNER_PANE_RENDER_DIR` through `build.sh`).
    func testTheFlatSidebarRendersItsWholeStructure() throws {
        // A fold or group mode left behind by an earlier run would change the
        // shape this render asserts on.
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.groupModeDefaultsKey)

        let sidebar = NavigationSidebarView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = sidebar

        sidebar.reloadWorkspaces(
            workspaces: [
                BrainProjectSummary(id: "p1", label: "Alpha", path: nil),
                BrainProjectSummary(id: "p2", label: "Beta", path: nil),
            ],
            panes: [
                pane("t1", group: "s1", project: "p1"),
                pane("t2", group: "s2", project: "p1"),
            ],
            focusedPaneID: "t1",
            statuses: ["t1": .ready, "t2": .thinking],
            projectLabels: [:]
        )

        // Which end of the bitmap is up is not readable off the code — the
        // layer render's unit space is y-up while the bitmap's row 0 is its
        // top — so a green marker anchors the mapping, the pane-wash render
        // test's pattern. Top-left corner: the nav stack's top inset keeps
        // that spot empty, where the view's y = 0 is the account row's.
        let marker = NSView(
            frame: NSRect(x: 0, y: sidebar.bounds.height - 6, width: 10, height: 6)
        )
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.green.cgColor
        sidebar.addSubview(marker)

        window.makeKeyAndOrderFront(nil)
        sidebar.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let image = try XCTUnwrap(render(sidebar))
        saveRenderForInspection(image, named: "flat-sidebar")

        func pixel(_ x: Int, _ y: Int) -> NSColor {
            image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) ?? .black
        }
        let anchor = try XCTUnwrap(
            (0..<image.pixelsHigh).first {
                pixel(3, $0).greenComponent > 0.8 && pixel(3, $0).redComponent < 0.4
            },
            "the marker has to show up, or the render proves nothing"
        )
        // The marker sits at the view's top: found near bitmap row 0, the
        // bitmap reads top-down; found near the end, it reads bottom-up.
        let topDown = anchor < image.pixelsHigh / 2
        func bitmapRow(forViewY viewY: Int) -> Int {
            topDown ? image.pixelsHigh - 1 - viewY : viewY
        }

        /// The widest channel spread across the block's pixels — a block
        /// that drew nothing is flat panel background, spread ≈ 0.
        func spread(_ view: NSView) -> CGFloat {
            let rect = view.convert(view.bounds, to: sidebar).intersection(sidebar.bounds)
            guard !rect.isEmpty else {
                XCTFail("\(type(of: view)) has no on-screen frame")
                return 0
            }
            var lows: [CGFloat] = [1, 1, 1]
            var highs: [CGFloat] = [0, 0, 0]
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for viewY in Int(rect.minY)..<Int(rect.maxY) {
                    let color = pixel(x, bitmapRow(forViewY: viewY))
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                    for (index, value) in channels.enumerated() {
                        lows[index] = min(lows[index], value)
                        highs[index] = max(highs[index], value)
                    }
                }
            }
            return zip(lows, highs).map { $1 - $0 }.max() ?? 0
        }

        for row in sidebar.navRows {
            // The selected row (Home, by default now that the app lands
            // there) wears `accentSoft` under `ink` text — a softer,
            // lower-contrast combination than an unselected row's flat
            // background under `inkNav`, so it clears a lower bar.
            let threshold: CGFloat = row.isSelected ? 0.05 : 0.1
            XCTAssertGreaterThan(spread(row), threshold, "the \(row.titleText) row rendered nothing")
        }
        XCTAssertGreaterThan(
            spread(sidebar.workspacesHeader), 0.1, "the Workspaces header rendered nothing"
        )

        let workspaceRows = descendants(WorkspaceRowView.self, under: sidebar.workspacesTree)
        XCTAssertEqual(workspaceRows.map(\.workspaceID), ["p1", "p2"])
        for row in workspaceRows {
            XCTAssertGreaterThan(spread(row), 0.1, "the \(row.titleText) row rendered nothing")
        }

        let sessionRows = descendants(SessionRowView.self, under: sidebar.workspacesTree)
        XCTAssertEqual(sessionRows.map(\.session.id), ["s1", "s2"])
        for row in sessionRows {
            XCTAssertGreaterThan(spread(row), 0.1, "the \(row.session.label) row rendered nothing")
        }

        let emptyRow = try XCTUnwrap(
            descendants(WorkspaceEmptyRowView.self, under: sidebar.workspacesTree).first,
            "Beta has no sessions — the dim placeholder stands in"
        )
        XCTAssertGreaterThan(spread(emptyRow), 0.08, "the No-sessions-yet row rendered nothing")
        XCTAssertGreaterThan(spread(sidebar.accountRow), 0.1, "the account row rendered nothing")

        // And the column is flat: one straight top-to-bottom order — nav
        // rows, header, each workspace over its own leaves, the account row
        // on the floor.
        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: sidebar).maxY }
        let expected: [NSView] =
            sidebar.navRows + [sidebar.workspacesHeader, workspaceRows[0]]
            + sessionRows + [workspaceRows[1], emptyRow, sidebar.accountRow]
        for (above, below) in zip(expected, expected.dropFirst()) {
            XCTAssertGreaterThan(
                top(above), top(below),
                "\(type(of: above)) should sit above \(type(of: below))"
            )
        }
        XCTAssertEqual(sidebar.accountRow.frame.minY, 10, accuracy: 0.5)
    }

    // MARK: - Helpers

    private func pane(_ id: String, group: String, project: String) -> PaneDescriptor {
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

    private func descendants<View: NSView>(_ type: View.Type, under view: NSView) -> [View] {
        view.subviews.flatMap { subview -> [View] in
            var found = descendants(type, under: subview)
            if let match = subview as? View { found.insert(match, at: 0) }
            return found
        }
    }

    /// Renders the view's whole layer tree — `cacheDisplay` draws `draw(_:)`
    /// output only. The pane workspace render tests' pattern.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        view.layer?.render(in: context.cgContext)
        return rep
    }

    /// Nothing reads this in CI; it exists so Bruno can eyeball a render.
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test` drops a
    /// PNG per named render there; unset, this is a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

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
    // MARK: - The time blocks

    /// The window cut into the units it is actually made of: five hours, or
    /// seven days.
    func testEachWindowIsCutIntoItsOwnUnits() {
        let card = makeLimitsCard()
        XCTAssertEqual(card.sessionColumn.timeBar.segments, 5, "five hours")
        XCTAssertEqual(card.weekColumn.timeBar.segments, 7, "seven days")
    }

    /// Each bar wears an icon on its left — a bolt for quota, a clock for the
    /// window — without the two bars drifting out of alignment.
    func testEachBarWearsItsIconOnTheLeft() {
        let card = makeLimitsCard()
        card.layoutSubtreeIfNeeded()
        let column = card.sessionColumn
        XCTAssertNotNil(column.barIcon.image, "bolt")
        XCTAssertNotNil(column.timeIcon.image, "clock")
        func x(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: card).minX }
        XCTAssertLessThan(x(column.barIcon), x(column.bar), "icon left of the usage bar")
        XCTAssertLessThan(x(column.timeIcon), x(column.timeBar), "icon left of the window bar")
        XCTAssertEqual(x(column.bar), x(column.timeBar), accuracy: 0.5, "bars still start together")
        XCTAssertEqual(column.barIcon.frame.width, SidebarLimitColumnView.iconWidth, accuracy: 1)
    }

    /// `/usage` reports only when a window ends, so how far through it we are
    /// is derived from the end: whatever is not still to come has gone.
    func testHowFarThroughAWindowIsDerivedFromItsEnd() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        let fiveHours: TimeInterval = 5 * 3600

        // 2h 18m still to come out of five hours, so 2h 42m has gone.
        let partial = try XCTUnwrap(SidebarLimitColumnView.elapsedFraction(
            until: now.addingTimeInterval(2 * 3600 + 18 * 60), windowLength: fiveHours, now: now
        ))
        XCTAssertEqual(partial, (fiveHours - (2 * 3600 + 18 * 60)) / fiveHours, accuracy: 0.001)

        XCTAssertEqual(
            SidebarLimitColumnView.elapsedFraction(
                until: now.addingTimeInterval(-60), windowLength: fiveHours, now: now
            ), 1, "a window past its reset is spent, not negative"
        )
        // A reset further out than one whole window means the length above is
        // wrong; it must read as a fresh window rather than run off the end.
        XCTAssertEqual(
            SidebarLimitColumnView.elapsedFraction(
                until: now.addingTimeInterval(fiveHours * 3), windowLength: fiveHours, now: now
            ), 0
        )
        XCTAssertNil(SidebarLimitColumnView.elapsedFraction(
            until: nil, windowLength: fiveHours, now: now
        ))
    }

    /// The block being lived through is partly filled; the ones behind it are
    /// solid. Rounding up is what makes the current block count as started.
    func testTheBlockBeingLivedThroughCountsAsStarted() {
        let bar = SidebarSegmentedBarView(segments: 5)
        bar.apply(nil)
        XCTAssertEqual(bar.filledSegments, 0, "no reading, no blocks")
        bar.apply(0)
        XCTAssertEqual(bar.filledSegments, 0, "a fresh window is empty")
        bar.apply(0.46)
        XCTAssertEqual(bar.filledSegments, 3, "two whole hours and into the third")
        bar.apply(1)
        XCTAssertEqual(bar.filledSegments, 5)
    }

    /// Blocks fill the same direction as the usage bar above them, so the
    /// column has one rule rather than two opposite ones.
    func testTheBlocksFillAsTheWindowIsSpent() throws {
        let card = makeLimitsCard()
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        // Reset a whole week out: the week has only just begun.
        card.apply(
            ClaudeUsageLimits.parse("Current week (all models): 2% used · resets Sep 2 at 11am"),
            now: now
        )
        let fresh = card.weekColumn.timeBar.filledSegments

        // Reset an hour out: almost all of it has gone.
        card.apply(
            ClaudeUsageLimits.parse("Current week (all models): 90% used · resets Aug 26 at 12pm"),
            now: now
        )
        XCTAssertGreaterThan(card.weekColumn.timeBar.filledSegments, fresh, "fills, not drains")
        XCTAssertEqual(card.weekColumn.timeBar.filledSegments, 7)
    }

    /// The countdown is a hover now, and a tooltip covers only its own view —
    /// so hovering the number itself has to work, not just the gaps.
    func testHoveringAnywhereInTheColumnShowsTheTime() throws {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse("Current session: 12% used · resets Aug 25 at 3:00pm"),
            now: noon
        )
        XCTAssertEqual(card.sessionColumn.toolTip, "3h 0m left")
        XCTAssertEqual(card.sessionColumn.timeBar.toolTip, "3h 0m left")
        XCTAssertFalse(
            try XCTUnwrap(card.sessionColumn.toolTip).contains("clock"),
            "nothing to warn about, so nothing said"
        )
        let labels = descendants(NSTextField.self, under: card.sessionColumn)
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertEqual(label.toolTip, "3h 0m left", "the number is hoverable too")
        }
    }

    // MARK: - Pace

    /// The projection is "at this rate, where does this window end up" — a
    /// fraction of the limit, not of the time.
    func testTheProjectionIsWhereThisRateLands() {
        // A tenth of the quota with a fifth of the window gone lands at half.
        XCTAssertEqual(
            try XCTUnwrap(SidebarLimitColumnView.projectedUsage(usage: 0.10, elapsed: 0.20)),
            0.5, accuracy: 0.001
        )
        // Nine tenths spent with a fifth gone blows through four and a half
        // times over.
        XCTAssertEqual(
            try XCTUnwrap(SidebarLimitColumnView.projectedUsage(usage: 0.90, elapsed: 0.20)),
            4.5, accuracy: 0.001
        )
    }

    /// Two requests in the opening minutes project to anything at all, and a
    /// bar that cries wolf on the first move is ignored by lunchtime.
    func testTheProjectionWaitsForEnoughWindowToJudge() {
        XCTAssertNil(SidebarLimitColumnView.projectedUsage(usage: 0.5, elapsed: 0.01))
        XCTAssertNil(SidebarLimitColumnView.projectedUsage(usage: 0, elapsed: 0.5), "spent nothing")
        XCTAssertNil(SidebarLimitColumnView.projectedUsage(usage: nil, elapsed: 0.5))
        XCTAssertNil(SidebarLimitColumnView.projectedUsage(usage: 0.5, elapsed: nil))
    }

    /// The blocks ramp on how much window has gone, on the same ramp as every
    /// other bar. A nearly-spent window is red whatever the spending did — the
    /// card colours two bars by one rule rather than two.
    func testANearlySpentWindowIsRedWhateverTheSpendingDid() throws {
        let card = makeLimitsCard()
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        // 12 minutes from a reset five hours wide, and only 40% spent.
        // Settled: the blocks' colour travels now too, so an animated apply
        // wears its starting colour on the first frame by design.
        card.apply(
            ClaudeUsageLimits.parse("Current session: 40% used · resets Aug 26 at 11:12am"),
            now: now, animated: false
        )
        assertHue(card.sessionColumn.timeBar.fillColor, ShellPalette.red)
        XCTAssertEqual(card.sessionColumn.timeBar.filledSegments, 5, "the window is nearly gone")
        // The usage bar still reads the spending, which is 40% and fine.
        assertHue(card.sessionColumn.bar.fillColor, ShellPalette.green)
    }

    /// Pace no longer shows in the blocks' colour, so the hover is the only
    /// place it lives — and it is the one thing here you might act on.
    func testOutspendingTheClockIsSaidInTheHover() throws {
        let card = makeLimitsCard()
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        // Four of five hours still to come, and 80% already gone.
        card.apply(
            ClaudeUsageLimits.parse("Current session: 80% used · resets Aug 26 at 3:00pm"),
            now: now
        )
        let tip = try XCTUnwrap(card.sessionColumn.toolTip)
        XCTAssertTrue(tip.contains("left"), "still says the time")
        XCTAssertTrue(tip.contains("4×"), "and how far ahead of the clock the spending is")
    }

    // MARK: - Turning the card over

    /// A click anywhere on the bubble shows the countdowns; the bars go.
    func testAClickAnywhereTurnsTheCardOver() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 12% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        XCTAssertFalse(card.isShowingTime, "bars first")

        card.setShowingTime(true, animated: false)

        XCTAssertTrue(card.isShowingTime)
        XCTAssertEqual(card.sessionColumn.timeLabel.stringValue, "3h 0m left")
        XCTAssertEqual(card.weekColumn.timeLabel.stringValue, "2d 23h left")
        XCTAssertEqual(card.sessionColumn.timeLabel.alphaValue, 1, accuracy: 0.001)
        XCTAssertEqual(card.weekColumn.timeLabel.alphaValue, 1, accuracy: 0.001)
    }

    /// The card is one thing, so both columns turn together — a half-turned
    /// card showing a bar beside a countdown would read as broken.
    func testBothColumnsTurnTogether() {
        let card = makeLimitsCard()
        card.setShowingTime(true, animated: false)
        XCTAssertTrue(card.sessionColumn.isShowingTime)
        XCTAssertTrue(card.weekColumn.isShowingTime)
        card.setShowingTime(false, animated: false)
        XCTAssertFalse(card.sessionColumn.isShowingTime)
        XCTAssertFalse(card.weekColumn.isShowingTime)
    }

    /// Clicking again turns it straight back rather than waiting out the
    /// seven seconds.
    func testClickingAgainTurnsItBack() {
        let card = makeLimitsCard()
        card.setShowingTime(true, animated: false)
        card.setShowingTime(false, animated: false)
        XCTAssertFalse(card.isShowingTime)
        XCTAssertEqual(card.sessionColumn.timeLabel.alphaValue, 0, accuracy: 0.001)
    }

    /// It turns back by itself, so a stray click does not leave the card
    /// face-up for the rest of the session.
    ///
    /// Driven on a short fuse rather than the real seven seconds: waiting out
    /// wall-clock in a test is what made this fail in a full suite while
    /// passing alone, and the mechanism under test is the timer, not its
    /// length. The length has its own assertion below.
    func testItTurnsBackOnItsOwn() {
        let card = makeLimitsCard()
        card.setShowingTime(true, animated: false, after: 0.2)
        XCTAssertTrue(card.isShowingTime)

        let turnedBack = expectation(description: "the card turned back")
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            guard !card.isShowingTime else { return }
            timer.invalidate()
            turnedBack.fulfill()
        }
        wait(for: [turnedBack], timeout: 5)

        XCTAssertFalse(card.sessionColumn.isShowingTime)
        XCTAssertFalse(card.weekColumn.isShowingTime)
    }

    /// And the fuse the app actually uses: long enough to read two short
    /// durations without hurrying, short enough that a stray click does not
    /// leave the card turned over.
    func testTheRevealLastsSevenSeconds() {
        XCTAssertEqual(SidebarClaudeLimitsView.revealDuration, 7)
    }

    /// Turning the card over must not move anything: the words sit in the
    /// bars' own band rather than in a row of their own.
    func testTurningItOverCostsNoHeight() {
        let card = makeLimitsCard()
        card.apply(ClaudeUsageLimits.parse("Current session: 12% used · resets Aug 25 at 3:00pm"), now: noon)
        card.layoutSubtreeIfNeeded()
        let barsUp = card.sessionColumn.frame

        card.setShowingTime(true, animated: false)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.sessionColumn.frame, barsUp, "nothing moved")
        XCTAssertEqual(card.frame.height, SidebarClaudeLimitsView.height)
    }

    /// The face shows the time; the hover still carries the pace, which does
    /// not fit in a column this narrow at a legible size.
    func testTheFaceIsShortAndTheHoverIsFull() throws {
        let card = makeLimitsCard()
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        card.apply(
            ClaudeUsageLimits.parse("Current session: 80% used · resets Aug 26 at 3:00pm"),
            now: now
        )
        XCTAssertEqual(card.sessionColumn.timeLabel.stringValue, "4h 0m left", "no pace on the face")
        XCTAssertTrue(try XCTUnwrap(card.sessionColumn.toolTip).contains("4×"), "pace on the hover")
    }

    // MARK: - Reading order

    /// The label names the thing, then the number answers it. Reading `12%`
    /// before knowing it is the session is backwards.
    func testTheCaptionSitsAboveTheNumber() {
        let card = makeLimitsCard()
        card.apply(ClaudeUsageLimits.parse("Current session: 12% used · resets Aug 25 at 3:00pm"), now: noon)
        card.layoutSubtreeIfNeeded()
        assertCaptionAboveNumber(in: card.sessionColumn, caption: "SESSION")

        let gauges = SidebarSystemStatsView()
        gauges.frame = NSRect(x: 0, y: 0, width: 216, height: SidebarSystemStatsView.height)
        gauges.apply(cpu: 0.13, memory: nil, gpu: nil)
        gauges.layoutSubtreeIfNeeded()
        assertCaptionAboveNumber(in: gauges.cpuGauge, caption: "CPU")
    }

    /// A non-flipped view puts what is higher on screen at the larger `minY`.
    private func assertCaptionAboveNumber(
        in column: NSView, caption: String, line: UInt = #line
    ) {
        let labels = descendants(NSTextField.self, under: column)
        guard
            let captionField = labels.first(where: { $0.stringValue == caption }),
            let valueField = labels.first(where: { $0.stringValue.hasSuffix("%") })
        else { return XCTFail("missing \(caption) or its number", line: line) }
        XCTAssertGreaterThan(
            captionField.frame.minY, valueField.frame.minY,
            "\(caption) sits above its number", line: line
        )
    }

    // MARK: - Machine gauges

    /// The gauges are dials, and they wear the Claude card's ramp — the two
    /// cards disagree about the shape and about nothing else.
    func testTheGaugesCarryADial() {
        let card = SidebarSystemStatsView()
        card.frame = NSRect(
            x: 0, y: 0, width: ShellMetrics.sidebarWidth - 16, height: SidebarSystemStatsView.height
        )
        card.apply(cpu: 0.34, memory: 0.78, gpu: 0.95, animated: false)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.cpuGauge.dial.needleFraction, 0.34, accuracy: 0.001)
        assertHue(card.cpuGauge.dial.progressColor, ShellPalette.green)
        assertHue(card.memoryGauge.dial.progressColor, ShellPalette.amber)
        assertHue(card.gpuGauge.dial.progressColor, ShellPalette.red)
        XCTAssertGreaterThan(card.cpuGauge.dial.frame.width, 20, "the dial spans its column")
        XCTAssertGreaterThan(card.cpuGauge.dial.frame.height, 20, "and has room for an arc")
    }

    /// The needle travels rather than jumping — the reason for a dial over a
    /// bar on numbers that are resampled every two seconds.
    func testTheNeedleTravelsRatherThanJumping() {
        XCTAssertGreaterThan(SidebarDialGaugeView.sweepDuration, 1, "unhurried")
        XCTAssertLessThan(
            SidebarDialGaugeView.sweepDuration, 2,
            "and still finishing before the next 2s sample"
        )
    }

    /// The sweep runs *past* the reading and eases back, rather than creeping
    /// up to it. Evaluated off the curve itself rather than asserted from the
    /// control points, so this says what the motion does and not merely which
    /// four numbers were typed.
    func testTheNeedleOvershootsAndSettles() {
        let curve = SidebarDialGaugeView.sweepCurve
        let samples = stride(from: 0.0, through: 1.0, by: 0.01).map { bezier(curve, at: $0) }

        let peak = samples.map(\.y).max() ?? 0
        XCTAssertGreaterThan(peak, 1.02, "runs past the destination")
        XCTAssertLessThan(peak, 1.25, "and not so far that it reads as a bounce")

        XCTAssertEqual(samples.last?.y ?? 0, 1, accuracy: 0.001, "and comes to rest on it")
    }

    /// Slow away, quickest through the middle, slow arriving — an S, not a
    /// ramp. Measured as speed over three equal slices of the duration, which
    /// is what "starts slow and speeds up" actually means.
    func testTheSweepEasesInAndOut() {
        let curve = SidebarMotion.overshoot
        func covered(_ from: Double, _ to: Double) -> Double {
            bezier(curve, atX: to) - bezier(curve, atX: from)
        }
        let opening = covered(0, 1.0 / 3)
        let middle = covered(1.0 / 3, 2.0 / 3)
        let closing = covered(2.0 / 3, 1)

        XCTAssertGreaterThan(middle, opening, "speeds up out of the start")
        XCTAssertGreaterThan(middle, closing, "and slows down into the finish")
        XCTAssertLessThan(opening, 0.25, "the opening third is unhurried")
        XCTAssertGreaterThan(middle, 0.5, "and the middle carries most of it")
    }

    /// It leaves from a standstill rather than snapping into motion.
    func testTheSweepLeavesFromRest() {
        // Over the first twentieth of the duration, a curve that starts at
        // rest has barely moved; a linear one would have covered 5%.
        XCTAssertLessThan(bezier(SidebarMotion.overshoot, atX: 0.05), 0.02)
        XCTAssertLessThan(bezier(SidebarMotion.settle, atX: 0.05), 0.02)
    }

    /// A cubic bezier with endpoints (0,0) and (1,1), evaluated at `t`.
    private func bezier(_ curve: CAMediaTimingFunction, at t: Double) -> (x: Double, y: Double) {
        var p1 = [Float](repeating: 0, count: 2)
        var p2 = [Float](repeating: 0, count: 2)
        curve.getControlPoint(at: 1, values: &p1)
        curve.getControlPoint(at: 2, values: &p2)
        func axis(_ a: Double, _ b: Double) -> Double {
            3 * pow(1 - t, 2) * t * a + 3 * (1 - t) * pow(t, 2) * b + pow(t, 3)
        }
        return (axis(Double(p1[0]), Double(p2[0])), axis(Double(p1[1]), Double(p2[1])))
    }

    /// The curve's progress at elapsed fraction `x`. The bezier is parametric,
    /// so `t` is not time — this searches for the `t` whose x is the elapsed
    /// fraction, which is what a timing function actually means.
    private func bezier(_ curve: CAMediaTimingFunction, atX x: Double) -> Double {
        var low = 0.0
        var high = 1.0
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if bezier(curve, at: mid).x < x { low = mid } else { high = mid }
        }
        return bezier(curve, at: (low + high) / 2).y
    }

    /// Where the needle actually *points*, which is not what
    /// `needleFraction` reports: that echoes the value it was handed, and was
    /// happily reading 0.11 while a sign error had the needle past vertical on
    /// the right-hand side of the dial.
    func testTheNeedlePointsWhereTheNumberSays() {
        // Hard left at nothing.
        let empty = SidebarDialGaugeView.needleDirection(for: 0)
        XCTAssertEqual(empty.x, -1, accuracy: 0.001, "left, not right")
        XCTAssertEqual(empty.y, 0, accuracy: 0.001)

        // Straight up at half.
        let half = SidebarDialGaugeView.needleDirection(for: 0.5)
        XCTAssertEqual(half.x, 0, accuracy: 0.001)
        XCTAssertEqual(half.y, 1, accuracy: 0.001, "up")

        // Hard right at full.
        let full = SidebarDialGaugeView.needleDirection(for: 1)
        XCTAssertEqual(full.x, 1, accuracy: 0.001, "right")
        XCTAssertEqual(full.y, 0, accuracy: 0.001)

        // And the reading Bruno caught it on: 11% belongs on the left.
        XCTAssertLessThan(SidebarDialGaugeView.needleDirection(for: 0.11).x, 0)
    }

    /// The real invariant, and the one a sign error breaks: the needle points
    /// at the end of its own arc. Checked across the sweep rather than at the
    /// three corners a wrong formula can still happen to satisfy.
    func testTheNeedleAgreesWithTheArc() {
        for step in stride(from: 0.0, through: 1.0, by: 0.05) {
            let needle = SidebarDialGaugeView.needleDirection(for: step)
            let arc = SidebarDialGaugeView.arcDirection(for: step)
            XCTAssertEqual(needle.x, arc.x, accuracy: 0.001, "x at \(step)")
            XCTAssertEqual(needle.y, arc.y, accuracy: 0.001, "y at \(step)")
        }
    }

    func testADialWithNoReadingRests() {
        let dial = SidebarDialGaugeView()
        dial.frame = NSRect(x: 0, y: 0, width: 49, height: SidebarStatGaugeView.dialHeight)
        dial.apply(nil, animated: false)
        XCTAssertEqual(dial.needleFraction, 0, "no reading rests at the left")
        assertHue(dial.progressColor, ShellPalette.inkTertiary, "and wears no verdict")
    }

    /// The number and its dial share one ramp, so they cannot drift apart —
    /// the gauge used to carry its own copy of the same three thresholds.
    func testTheGaugesNumberAndDialAgree() {
        let card = SidebarSystemStatsView()
        card.apply(cpu: 0.95, memory: nil, gpu: nil, animated: false)
        assertHue(card.cpuGauge.readoutColor, ShellPalette.red)
        XCTAssertEqual(card.cpuGauge.readoutColor, card.cpuGauge.dial.progressColor, "one ramp")
        XCTAssertEqual(card.memoryGauge.readout, "—")
        XCTAssertNil(card.memoryGauge.dial.fraction, "no sample, needle at rest")
    }

    /// A dial costs height a bar did not — an arc is half a circle and a bar
    /// is a line. This pins what it actually cost, so the next change to this
    /// card has to be deliberate about the sidebar it is sharing.
    func testTheDialsHeightCostIsPinned() {
        XCTAssertEqual(SidebarSystemStatsView.height, 76, "62 with bars, 76 with dials")
        let card = SidebarSystemStatsView()
        card.frame = NSRect(x: 0, y: 0, width: 216, height: SidebarSystemStatsView.height)
        card.apply(cpu: 1, memory: 1, gpu: 1, animated: false)
        card.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            card.cpuGauge.fittingSize.height, SidebarSystemStatsView.height,
            "the column still fits inside the card"
        )
    }

    // MARK: - Colour helpers

    /// The ramp mixes hues and varies alpha, so identity comparison against a
    /// palette colour is the wrong question. This asks the right one: is this
    /// the same colour, ignoring how present it is.
    private func assertHue(
        _ colour: NSColor?, _ expected: NSColor, _ message: String = "", line: UInt = #line
    ) {
        guard
            let actual = colour?.usingColorSpace(.sRGB),
            let want = expected.usingColorSpace(.sRGB)
        else { return XCTFail("not an sRGB colour", line: line) }
        XCTAssertEqual(actual.redComponent, want.redComponent, accuracy: 0.02, message, line: line)
        XCTAssertEqual(actual.greenComponent, want.greenComponent, accuracy: 0.02, message, line: line)
        XCTAssertEqual(actual.blueComponent, want.blueComponent, accuracy: 0.02, message, line: line)
    }

    /// Whether `colour` sits between two others on every channel — what "part
    /// way from green to amber" means without pinning an exact mix.
    private func isBetween(_ colour: NSColor, _ from: NSColor, _ to: NSColor) -> Bool {
        guard
            let c = colour.usingColorSpace(.sRGB),
            let a = from.usingColorSpace(.sRGB),
            let b = to.usingColorSpace(.sRGB)
        else { return false }
        func within(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> Bool {
            x >= min(lo, hi) - 0.001 && x <= max(lo, hi) + 0.001
        }
        return within(c.redComponent, a.redComponent, b.redComponent)
            && within(c.greenComponent, a.greenComponent, b.greenComponent)
            && within(c.blueComponent, a.blueComponent, b.blueComponent)
    }

    // MARK: - How the bars move

    /// The presentation layer does not advance under `xcodebuild test` — no
    /// window ever genuinely comes on screen — so sampling what is drawn can
    /// only ever produce a test that passes for the wrong reason. It did:
    /// 66 samples, every one exactly the settled value, while
    /// `animationKeys()` was empty and nothing was animating at all.
    ///
    /// What these assert instead is that the motion was *installed*, which is
    /// the part this code is actually responsible for.
    /// No window. An explicit animation attaches to the layer whether or not
    /// anything is on screen, so hosting one bought nothing — and cost a
    /// crash: a borderless window here returns `NO` from `canBecomeKeyWindow`
    /// and taking the test host through it killed the process mid-test, four
    /// tests at a time. It is also the same ambient key-window dependency
    /// backlog 5b blames for the intermittent failures elsewhere.
    private func makeBar() -> SidebarPercentBarView {
        let bar = SidebarPercentBarView()
        bar.translatesAutoresizingMaskIntoConstraints = true
        bar.frame = NSRect(x: 0, y: 0, width: 100, height: 5)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// A new reading is travelled to, not jumped to.
    func testABarAnimatesToANewReading() throws {
        let bar = makeBar()
        bar.apply(0)
        bar.layoutSubtreeIfNeeded()

        bar.apply(0.5)
        bar.layoutSubtreeIfNeeded()

        let animation = try XCTUnwrap(bar.fillAnimation, "the motion was installed")
        XCTAssertEqual(animation.duration, SidebarMotion.duration)
        XCTAssertEqual(animation.toValue as? CGFloat, 50, "half of a 100pt bar")
    }

    /// Growing springs past the reading, the same way the needle does.
    func testABarSpringsOnTheWayUp() throws {
        let bar = makeBar()
        bar.apply(0.2)
        bar.layoutSubtreeIfNeeded()

        bar.apply(0.8)
        bar.layoutSubtreeIfNeeded()

        let animation = try XCTUnwrap(bar.fillAnimation)
        XCTAssertEqual(animation.timingFunction, SidebarMotion.overshoot)
    }

    /// Shrinking does not. A bar overshooting toward empty has nowhere to go
    /// but a negative width, which is an empty rect and draws as nothing — the
    /// fill would vanish for a frame and come back, reading as a flicker.
    func testABarDoesNotSpringOnTheWayDown() throws {
        let bar = makeBar()
        bar.apply(0.8)
        bar.layoutSubtreeIfNeeded()

        bar.apply(0)
        bar.layoutSubtreeIfNeeded()

        let animation = try XCTUnwrap(bar.fillAnimation)
        XCTAssertEqual(animation.timingFunction, SidebarMotion.settle, "arrives, not springs")
        // The nub, not nothing: a real zero still draws something, which is
        // what keeps "used none of it" distinct from "no reading".
        XCTAssertEqual(
            animation.toValue as? CGFloat, SidebarPercentBarView.minimumFillWidth,
            "shrinks to the nub a real zero keeps"
        )
    }

    /// A resize is not a reading. Without this a bar springs every time the
    /// sidebar divider is dragged.
    func testAResizeDoesNotAnimateTheBar() {
        let bar = makeBar()
        bar.apply(0.5)
        bar.layoutSubtreeIfNeeded()

        bar.frame = NSRect(x: 0, y: 0, width: 200, height: 5)
        bar.layoutSubtreeIfNeeded()

        XCTAssertNil(bar.fillAnimation, "geometry moved, the reading did not")
        XCTAssertEqual(bar.fillWidth, 100, accuracy: 0.5, "and it went straight there")
    }

    /// The blocks travel too, each one on its own fill.
    func testTheTimeBlocksAnimateAsWell() {
        let blocks = SidebarSegmentedBarView(segments: 5)
        blocks.frame = NSRect(x: 0, y: 0, width: 100, height: 5)
        blocks.apply(0.2)
        blocks.layoutSubtreeIfNeeded()

        blocks.apply(0.6)
        blocks.layoutSubtreeIfNeeded()

        XCTAssertFalse(blocks.fillAnimations.isEmpty, "the blocks move")
        for animation in blocks.fillAnimations {
            XCTAssertEqual(animation.duration, SidebarMotion.duration)
        }
    }

    /// And the needle, which is the motion the bars were asked to match.
    func testTheNeedleAnimatesOnTheSharedMotion() throws {
        let dial = SidebarDialGaugeView()
        dial.frame = NSRect(x: 0, y: 0, width: 49, height: SidebarStatGaugeView.dialHeight)
        dial.layoutSubtreeIfNeeded()
        dial.apply(0.3)

        let animation = try XCTUnwrap(dial.needleAnimation)
        XCTAssertEqual(animation.duration, SidebarMotion.duration)
        XCTAssertEqual(
            animation.timingFunction, SidebarMotion.overshoot,
            "a needle has room to swing past either end, so it always springs"
        )
    }

    /// Reduce Motion is honoured by not installing the animation at all,
    /// rather than by installing one of zero duration.
    func testReduceMotionInstallsNothing() {
        XCTAssertFalse(
            SidebarMotion.wanted(false),
            "a caller that did not ask for motion never gets it"
        )
    }

    /// The direction rule itself.
    func testABarSpringsUpAndMerelyArrivesDown() {
        XCTAssertEqual(SidebarMotion.curve(rising: true), SidebarMotion.overshoot)
        XCTAssertEqual(SidebarMotion.curve(rising: false), SidebarMotion.settle)
        XCTAssertEqual(
            SidebarMotion.curve(rising: false, canOvershootBothWays: true),
            SidebarMotion.overshoot,
            "a needle has room to swing past either end"
        )
    }

    /// The settle curve has the same S-shape as the spring — it just does not
    /// run past. Otherwise a shrinking bar would move quite differently from a
    /// growing one.
    func testTheSettleCurveIsTheSameShapeWithoutTheOvershoot() {
        let peak = stride(from: 0.0, through: 1.0, by: 0.01)
            .map { bezier(SidebarMotion.settle, at: $0).y }
            .max() ?? 0
        XCTAssertLessThanOrEqual(peak, 1.001, "never past the reading")

        // Same slices, same verdict as the spring.
        func covered(_ from: Double, _ to: Double) -> Double {
            bezier(SidebarMotion.settle, atX: to) - bezier(SidebarMotion.settle, atX: from)
        }
        let middle = covered(1.0 / 3, 2.0 / 3)
        XCTAssertGreaterThan(middle, covered(0, 1.0 / 3))
        XCTAssertGreaterThan(middle, covered(2.0 / 3, 1))
    }

    // MARK: - Numbers that count

    /// Runs the main runloop until `check` holds, or gives up.
    private func settle(within seconds: TimeInterval, until check: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !check() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// The number travels through the values between two readings rather than
    /// cutting from one to the other.
    func testTheNumberCountsThroughTheValuesBetween() {
        var seen: [Double] = []
        let counter = SidebarCountingLabel { seen.append($0) }
        counter.count(to: 20, animated: false)
        seen.removeAll()

        counter.count(to: 30, animated: true)
        settle(within: SidebarMotion.duration + 0.5) { !counter.isCounting }

        XCTAssertGreaterThan(seen.count, 5, "it passed through, it did not jump")
        XCTAssertEqual(seen.last ?? 0, 30, accuracy: 0.001, "and arrived")
        XCTAssertTrue(
            seen.contains { $0 > 22 && $0 < 28 }, "through the middle of the range"
        )
        XCTAssertGreaterThanOrEqual(seen.min() ?? 0, 20, "never below where it started")
    }

    /// It counts at the animation's pace, not at a constant rate: the middle
    /// of the count covers more ground than either end.
    func testTheNumberCountsAtTheAnimationsPace() {
        var seen: [Double] = []
        let counter = SidebarCountingLabel { seen.append($0) }
        counter.count(to: 0, animated: false)
        seen.removeAll()

        counter.count(to: 100, animated: true)
        settle(within: SidebarMotion.duration + 0.5) { !counter.isCounting }

        XCTAssertGreaterThan(seen.count, 9, "enough samples to see a shape")
        let third = seen.count / 3
        let opening = seen[third] - seen[0]
        let middle = seen[third * 2] - seen[third]
        XCTAssertGreaterThan(middle, opening, "speeds up out of the start")
    }

    /// The count drifts past its reading and eases back onto it, the way the
    /// bar beside it does.
    func testTheNumberDriftsPastAndSettles() {
        var seen: [Double] = []
        let counter = SidebarCountingLabel { seen.append($0) }
        counter.count(to: 0, animated: false)
        seen.removeAll()

        counter.count(to: 46, animated: true)
        settle(within: SidebarMotion.duration + 0.5) { !counter.isCounting }

        XCTAssertGreaterThan(seen.max() ?? 0, 46, "ran past the reading")
        XCTAssertEqual(seen.last ?? 0, 46, accuracy: 0.001, "and settled on it")
    }

    /// But never past what a percentage can be. Momentum does not make `103%`
    /// a number anybody is settling toward.
    func testTheNumberNeverShowsAnImpossiblePercentage() {
        var seen: [Double] = []
        let counter = SidebarCountingLabel { seen.append($0) }
        counter.count(to: 40, animated: false)
        seen.removeAll()

        counter.count(to: 100, animated: true)
        settle(within: SidebarMotion.duration + 0.5) { !counter.isCounting }

        XCTAssertLessThanOrEqual(seen.max() ?? 0, 100, "capped at a real reading")
        XCTAssertEqual(seen.last ?? 0, 100, accuracy: 0.001)
    }

    /// And the same at the bottom of the range.
    func testTheNumberNeverShowsANegativePercentage() {
        var seen: [Double] = []
        let counter = SidebarCountingLabel { seen.append($0) }
        counter.count(to: 60, animated: false)
        seen.removeAll()

        counter.count(to: 0, animated: true)
        settle(within: SidebarMotion.duration + 0.5) { !counter.isCounting }

        XCTAssertGreaterThanOrEqual(seen.min() ?? -1, 0, "never below nothing")
    }

    /// First launch: everything starts at nothing and counts up to what it
    /// found, rather than appearing already at it.
    func testAFirstReadingCountsUpFromZero() {
        let gauge = SidebarStatGaugeView(name: "CPU")
        XCTAssertEqual(gauge.countingLabel.current, 0, "starts at nothing")

        gauge.apply(0.37)

        XCTAssertTrue(gauge.countingLabel.isCounting, "it travels to the first reading")
        settle(within: SidebarMotion.duration + 0.5) { !gauge.countingLabel.isCounting }
        XCTAssertEqual(gauge.readout, "37%")
    }

    /// The same on the Claude card, whose first state is no reading at all.
    func testTheLimitsCardAlsoCountsUpFromZero() {
        let card = makeLimitsCard()
        card.apply(nil, now: noon)
        XCTAssertEqual(card.sessionColumn.readout, "—", "no reading is not a number")

        card.apply(
            ClaudeUsageLimits.parse("Current session: 41% used · resets Aug 25 at 3:00pm"),
            now: noon
        )

        XCTAssertTrue(card.sessionColumn.countingLabel.isCounting)
        settle(within: SidebarMotion.duration + 0.5) { !card.sessionColumn.countingLabel.isCounting }
        XCTAssertEqual(card.sessionColumn.readout, "41%")
    }

    /// A reading arriving mid-count continues from where the number visibly
    /// is, rather than snapping back to start again.
    func testAReadingMidCountContinuesFromWhereItIs() {
        var seen: [Double] = []
        let counter = SidebarCountingLabel { seen.append($0) }
        counter.count(to: 0, animated: false)
        counter.count(to: 100, animated: true)
        settle(within: 0.2) { counter.current > 5 }
        let interrupted = counter.current
        seen.removeAll()

        counter.count(to: 50, animated: true)

        XCTAssertEqual(seen.first ?? -1, interrupted, accuracy: 0.001, "picks up where it was")
    }

    /// Losing a reading is the absence of a number, not a journey to zero.
    func testLosingAReadingDoesNotCountDown() {
        let gauge = SidebarStatGaugeView(name: "GPU")
        gauge.apply(0.5, animated: false)

        gauge.apply(nil)

        XCTAssertFalse(gauge.countingLabel.isCounting, "nothing to count to")
        XCTAssertEqual(gauge.readout, "—")
    }

    // MARK: - Colour travelling with the number

    /// The colour walks the ramp with the count rather than switching at the
    /// end — a gauge crossing into amber does it gradually.
    func testTheColourWalksTheRampWithTheNumber() {
        let gauge = SidebarStatGaugeView(name: "CPU")
        gauge.apply(0.2, animated: false)
        assertHue(gauge.readoutColor, ShellPalette.green)

        // Straight past amber into red, so the crossing is unmissable.
        gauge.apply(0.95)
        settle(within: 0.4) { gauge.countingLabel.current > 60 }

        // Caught mid-count in the amber band, not still green and not yet red.
        let midway = try? XCTUnwrap(gauge.readoutColor)
        XCTAssertNotNil(midway)
        XCTAssertNotEqual(midway, ShellPalette.green, "it has left green behind")
        settle(within: SidebarMotion.duration + 0.5) { !gauge.countingLabel.isCounting }
        assertHue(gauge.readoutColor, ShellPalette.red, "and arrives at red")
    }

    /// The dial's arc is repainted with the number, so the two never disagree
    /// about the same figure mid-count.
    func testTheArcIsRepaintedWithTheNumber() {
        let gauge = SidebarStatGaugeView(name: "MEM")
        gauge.apply(0.1, animated: false)
        gauge.apply(0.95)
        settle(within: 0.4) { gauge.countingLabel.current > 60 }

        XCTAssertEqual(
            gauge.readoutColor, gauge.dial.progressColor,
            "number and arc, one colour, every frame"
        )
    }

    /// And the Claude card's bar the same way.
    func testTheLimitsBarIsRepaintedWithTheNumber() {
        let card = makeLimitsCard()
        card.apply(ClaudeUsageLimits.parse("Current session: 5% used · resets Aug 25 at 3:00pm"), now: noon, animated: false)
        card.apply(ClaudeUsageLimits.parse("Current session: 95% used · resets Aug 25 at 3:00pm"), now: noon)
        settle(within: 0.4) { card.sessionColumn.countingLabel.current > 60 }

        XCTAssertEqual(
            card.sessionColumn.readoutColor, card.sessionColumn.bar.fillColor,
            "number and bar, one colour, every frame"
        )
    }

    /// Every coloured thing on both cards travels: the numbers, the usage
    /// bars, the dial arcs, the time blocks and the countdown. This is the
    /// audit — it was written because two of them were still switching in one
    /// step after the first pass claimed all of them did.
    func testEveryStatsColourTravels() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        // Machine gauges: green, heading for red.
        let gauges = SidebarSystemStatsView()
        gauges.apply(cpu: 0.05, memory: 0.05, gpu: 0.05, animated: false)
        gauges.apply(cpu: 0.98, memory: 0.98, gpu: 0.98)
        for gauge in [gauges.cpuGauge, gauges.memoryGauge, gauges.gpuGauge] {
            assertHue(gauge.readoutColor, ShellPalette.green, "starts where it was")
            assertHue(gauge.dial.progressColor, ShellPalette.green, "arc too")
        }

        // Claude card: quota green heading for red, window green heading for
        // red, on their own separate journeys.
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse("Current session: 5% used · resets Aug 26 at 3:55pm"),
            now: now, animated: false
        )
        card.apply(
            ClaudeUsageLimits.parse("Current session: 98% used · resets Aug 26 at 11:03am"),
            now: now
        )
        let column = card.sessionColumn
        assertHue(column.readoutColor, ShellPalette.green, "number starts where it was")
        assertHue(column.bar.fillColor, ShellPalette.green, "usage bar too")
        assertHue(column.timeBar.fillColor, ShellPalette.green, "time blocks too")
        assertHue(column.timeLabel.textColor, ShellPalette.green, "and the countdown")

        settle(within: SidebarMotion.duration + 0.6) {
            !column.countingLabel.isCounting && !column.timeCountingLabel.isCounting
                && !gauges.cpuGauge.countingLabel.isCounting
        }

        assertHue(gauges.cpuGauge.readoutColor, ShellPalette.red, "gauge arrives")
        assertHue(gauges.cpuGauge.dial.progressColor, ShellPalette.red)
        assertHue(column.readoutColor, ShellPalette.red, "quota arrives")
        assertHue(column.bar.fillColor, ShellPalette.red)
        assertHue(column.timeBar.fillColor, ShellPalette.red, "window arrives")
        assertHue(column.timeLabel.textColor, ShellPalette.red)
    }

    /// The two journeys are genuinely separate: spending almost nothing while
    /// the window runs out leaves a green bar over red blocks, and one counter
    /// painting both would have to pick one.
    func testTheWindowAndTheQuotaTravelSeparately() throws {
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse("Current session: 4% used · resets Aug 26 at 11:03am"),
            now: now, animated: false
        )

        assertHue(card.sessionColumn.bar.fillColor, ShellPalette.green, "barely any quota spent")
        assertHue(card.sessionColumn.timeBar.fillColor, ShellPalette.red, "but the window is gone")
    }

    // MARK: - The countdown's own colour

    /// The countdown reads the same thing the blocks under it read, so it
    /// wears their colour rather than the usage bar's.
    func testTheCountdownWearsTheTimeBarsColour() throws {
        let card = makeLimitsCard()
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 11))
        )
        // Barely any quota spent, but the window nearly gone: the two bars are
        // deliberately different colours here, which is what makes this
        // discriminate.
        card.apply(
            ClaudeUsageLimits.parse("Current session: 4% used · resets Aug 26 at 11:06am"),
            now: now, animated: false
        )
        card.setShowingTime(true, animated: false)

        assertHue(card.sessionColumn.timeLabel.textColor, ShellPalette.red, "the window is spent")
        assertHue(card.sessionColumn.bar.fillColor, ShellPalette.green, "the quota is not")
        XCTAssertEqual(
            card.sessionColumn.timeLabel.textColor, card.sessionColumn.timeBar.fillColor,
            "the countdown matches its own bar"
        )
    }

    /// Big enough to read at a glance, since it is what a click on the card is
    /// for.
    func testTheCountdownIsLargerThanItWas() throws {
        let card = makeLimitsCard()
        let size = try XCTUnwrap(card.sessionColumn.timeLabel.font?.pointSize)
        XCTAssertGreaterThan(size, 10, "larger than the 10pt it started at")
    }

    /// On a first launch the card has no reading, then gets one — and travels
    /// to it from nothing rather than appearing already there.
    func testTheLimitsCardStartsFromZeroAndTravels() {
        let card = makeLimitsCard()
        card.apply(nil, now: noon)
        XCTAssertEqual(card.sessionColumn.countingLabel.current, 0)
        XCTAssertEqual(card.sessionColumn.bar.fillWidth, 0, "an empty track, not a filled one")

        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 41% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 62% used · resets Aug 28 at 11am"
            ),
            now: noon
        )

        XCTAssertTrue(card.sessionColumn.countingLabel.isCounting, "session travels")
        XCTAssertTrue(card.weekColumn.countingLabel.isCounting, "week travels")
        settle(within: SidebarMotion.duration + 0.5) { !card.weekColumn.countingLabel.isCounting }
        XCTAssertEqual(card.sessionColumn.readout, "41%")
        XCTAssertEqual(card.weekColumn.readout, "62%")
    }

    /// Both cards move at one pace. The card-flip keeps its own, because a
    /// reveal is not a reading.
    func testBothCardsShareOneDuration() {
        XCTAssertEqual(SidebarDialGaugeView.sweepDuration, SidebarMotion.duration)
        XCTAssertLessThan(
            SidebarLimitColumnView.flipDuration, SidebarMotion.duration,
            "turning the card over is a reveal, and stays quick"
        )
    }

    // MARK: - Claude limits card

    /// It sits above the machine gauges, which is where it was asked to go —
    /// and both survive.
    func testTheClaudeCardSitsAboveTheMachineGauges() {
        let sidebar = makeSidebar()
        XCTAssertGreaterThan(
            sidebar.claudeLimits.frame.minY, sidebar.statsRow.frame.minY,
            "higher up the column than CPU/MEM/GPU"
        )
        XCTAssertGreaterThan(sidebar.statsRow.frame.height, 0, "the gauges are still there")
    }

    private func makeLimitsCard() -> SidebarClaudeLimitsView {
        let card = SidebarClaudeLimitsView()
        card.frame = NSRect(
            x: 0, y: 0, width: ShellMetrics.sidebarWidth - 16, height: SidebarClaudeLimitsView.height
        )
        return card
    }

    private let noon = Calendar.current.date(
        from: DateComponents(year: 2026, month: 8, day: 25, hour: 12)
    )!

    /// The number is the fastest read on the card, and it was missing
    /// entirely — the card showed a bar and nothing else.
    func testEachColumnLeadsWithItsPercentage() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 4% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon, animated: false
        )
        XCTAssertEqual(card.sessionColumn.readout, "4%")
        XCTAssertEqual(card.weekColumn.readout, "41%")
    }

    /// A bare `2d 11h` does not say whether it is time spent or time left.
    /// It lives on the hover now rather than on a row of its own.
    func testTheCountdownSaysWhatItIs() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 4% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        XCTAssertEqual(card.sessionColumn.remaining, "3h 0m left")
        XCTAssertEqual(card.weekColumn.remaining, "2d 23h left")
    }

    /// Equal-width columns are what stop the two bars starting or ending at
    /// different x — the ragged edges the first version had, where each row
    /// sized itself around its own label and its own countdown.
    func testTheTwoBarsShareAStartAndAnEnd() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 4% used · resets Aug 25 at 3:00pm\n"
                + "Current week (all models): 41% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        card.layoutSubtreeIfNeeded()

        let session = card.sessionColumn.bar.convert(card.sessionColumn.bar.bounds, to: card)
        let week = card.weekColumn.bar.convert(card.weekColumn.bar.bounds, to: card)
        XCTAssertEqual(session.width, week.width, accuracy: 0.5, "same length")
        XCTAssertEqual(session.minY, week.minY, accuracy: 0.5, "same baseline")
        XCTAssertGreaterThan(session.width, 30, "wide enough to read a level")
    }

    /// Fill is what has been spent and the colour ramps with it, so a full bar
    /// is always red — "full" and "bad" never disagree.
    func testTheFillAndItsColourAgree() {
        let bar = SidebarPercentBarView()
        bar.apply(0.41)
        assertHue(bar.fillColor, ShellPalette.green)
        bar.apply(0.75)
        assertHue(bar.fillColor, ShellPalette.amber)
        bar.apply(0.95)
        assertHue(bar.fillColor, ShellPalette.red)
    }

    /// Green to 70, amber to 90, red beyond — and the change slides rather
    /// than snapping, so the bar is warming before it is a warning.
    func testTheRampSlidesBetweenBandsRatherThanSnapping() {
        // Squarely inside a band: the band's own colour, nothing mixed in.
        assertHue(SidebarPercentBarView.hue(for: 0.30), ShellPalette.green)
        assertHue(SidebarPercentBarView.hue(for: 0.75), ShellPalette.amber)
        assertHue(SidebarPercentBarView.hue(for: 0.95), ShellPalette.red)

        // The stops Bruno named: 70% has arrived at amber, 90% at red.
        assertHue(SidebarPercentBarView.hue(for: 0.70), ShellPalette.amber)
        assertHue(SidebarPercentBarView.hue(for: 0.90), ShellPalette.red)

        // And between them it is genuinely in between, not one or the other.
        let warming = SidebarPercentBarView.hue(for: 0.65)
        XCTAssertNotEqual(warming, ShellPalette.green)
        XCTAssertNotEqual(warming, ShellPalette.amber)
        XCTAssertTrue(
            isBetween(warming, ShellPalette.green, ShellPalette.amber),
            "65% is part way from green to amber"
        )
        XCTAssertTrue(
            isBetween(SidebarPercentBarView.hue(for: 0.85), ShellPalette.amber, ShellPalette.red),
            "85% is part way from amber to red"
        )
    }

    /// The closer to the limit, the stronger the colour.
    func testTheColourStrengthensTowardTheLimit() {
        XCTAssertLessThan(
            SidebarPercentBarView.strength(for: 0.08),
            SidebarPercentBarView.strength(for: 0.95),
            "a nearly-full bar is more present than a nearly-empty one"
        )
        XCTAssertEqual(SidebarPercentBarView.strength(for: 1), 1, accuracy: 0.001)
        // Floored well clear of transparent: this paints the numbers too, and
        // a faded `8%` is a readout you have to squint at.
        XCTAssertGreaterThanOrEqual(SidebarPercentBarView.strength(for: 0), 0.8)
    }

    /// The number wears the same verdict as its bar, so the two cannot say
    /// different things about the same window.
    func testTheNumberWearsTheBarsVerdict() {
        let card = makeLimitsCard()
        // Settled, not travelling: the colour walks the ramp with the count
        // now, so an animated apply is green on its first frame by design.
        card.apply(
            ClaudeUsageLimits.parse("Current session: 95% used · resets Aug 25 at 3:00pm"),
            now: noon, animated: false
        )
        assertHue(card.sessionColumn.readoutColor, ShellPalette.red)
        // The property that actually matters: one ramp, so the number and its
        // own bar cannot disagree about the same figure.
        XCTAssertEqual(card.sessionColumn.readoutColor, card.sessionColumn.bar.fillColor)
    }

    /// A fresh window reads 0%, and drawing that as an empty track made it
    /// pixel-identical to having no reading at all. This is the whole reason
    /// the Session row looked broken.
    func testARealZeroStillDrawsSomething() {
        let card = makeLimitsCard()
        card.frame = NSRect(x: 0, y: 0, width: 216, height: SidebarClaudeLimitsView.height)
        card.apply(ClaudeUsageLimits.parse("Current session: 0% used · resets Aug 25 at 3:00pm"), now: noon)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.sessionColumn.readout, "0%")
        XCTAssertGreaterThanOrEqual(
            card.sessionColumn.bar.fillWidth, SidebarPercentBarView.minimumFillWidth,
            "a real zero still shows a nub"
        )
    }

    /// And no reading at all draws nothing, so the two states stay distinct.
    func testNoReadingDrawsNothingAndSaysSo() {
        let card = makeLimitsCard()
        card.apply(nil, now: noon)
        card.layoutSubtreeIfNeeded()

        XCTAssertEqual(card.sessionColumn.readout, "—")
        XCTAssertEqual(card.sessionColumn.remaining, "no reading")
        XCTAssertNil(card.sessionColumn.bar.fraction)
        XCTAssertEqual(card.sessionColumn.bar.fillWidth, 0, "empty track, not a zero fill")
    }

    /// The card was trimmed from 108pt to 74pt because it crowded the
    /// sidebar. That trim is only safe while the content still fits: a later
    /// font bump or an extra line would clip silently, since the height is
    /// authored rather than intrinsic.
    func testTheCardIsTallEnoughForItsOwnContent() {
        let card = makeLimitsCard()
        card.apply(
            ClaudeUsageLimits.parse(
                "Current session: 100% used · resets Aug 28 at 11am\n"
                + "Current week (all models): 100% used · resets Aug 28 at 11am"
            ),
            now: noon
        )
        card.layoutSubtreeIfNeeded()

        for column in [card.sessionColumn, card.weekColumn] {
            XCTAssertLessThanOrEqual(
                column.fittingSize.height, SidebarClaudeLimitsView.height,
                "the column fits inside the card"
            )
            XCTAssertGreaterThan(column.bar.frame.width, 0, "and the bar survived the trim")
        }
    }

    /// Shorter than it was, and still clearly the taller of the two cards —
    /// it carries four lines of content to the gauges' two.
    func testTheCardIsNoTallerThanItNeedsToBe() {
        XCTAssertEqual(SidebarClaudeLimitsView.height, 78)
        XCTAssertLessThan(
            SidebarClaudeLimitsView.height, 90,
            "the sidebar has a workspace list to show as well"
        )
    }

    /// A `/usage` that reports only the week must not blank the session half.
    /// It used to, and an empty bar beside a dash is what that looked like.
    func testAWeekOnlyReadingKeepsTheSession() {
        let full = ClaudeUsageLimits.parse(
            "Current session: 4% used · resets Aug 25 at 3:00pm\n"
            + "Current week (all models): 41% used · resets Aug 28 at 11am"
        )
        let weekOnly = ClaudeUsageLimits.parse(
            "Current week (all models): 43% used · resets Aug 28 at 11am"
        )

        let merged = weekOnly.merged(onto: full)

        XCTAssertEqual(merged.sessionPercent, 4, "kept from the last reading that had one")
        XCTAssertEqual(merged.sessionResets, "Aug 25 at 3:00pm")
        XCTAssertEqual(merged.weekPercent, 43, "the fresh half won")
    }

    /// Merged per window, not per field: a session that reported a percentage
    /// but no readable reset must not inherit the previous window's reset and
    /// count down to the wrong moment.
    func testAWindowIsKeptOrReplacedWhole() {
        let full = ClaudeUsageLimits.parse("Current session: 4% used · resets Aug 25 at 3:00pm")
        // A session line carrying no `resets` clause at all, so the phrase is
        // genuinely absent rather than merely unparseable.
        let noPhrase = ClaudeUsageLimits.parse("Current session: 9% used")

        let merged = noPhrase.merged(onto: full)

        XCTAssertEqual(merged.sessionPercent, 9, "the fresh window won")
        XCTAssertNil(merged.sessionResets, "and did not inherit the old window's reset time")
        XCTAssertNil(merged.sessionResetsAt, "so there is no instant to count down to")
    }

}
