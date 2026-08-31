import XCTest
@testable import OmniAgent

final class CommandPaletteTests: XCTestCase {
    // MARK: - the list

    func testEveryLivePaneIsSwitchableNamedByProjectSessionAndPane() {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1", groupLabel: "Build", label: "migrate"),
                pane("b", project: "beta", group: "g2"),
            ],
            paneOrder: ["a", "b"],
            focusedPaneID: "a"
        )

        let switches = commands.filter { $0.id.hasPrefix("focus:") }
        XCTAssertEqual(switches.map(\.title), ["migrate", "Shell 1"])
        XCTAssertEqual(switches.map(\.subtitle), ["alpha · Build", "beta · Session 1"], "the location is its own line")
        XCTAssertEqual(switches.map(\.detail), ["shell", "shell"])
    }

    func testAnEmptyWorkspaceStillOffersThePlaces() {
        XCTAssertEqual(
            CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
                .map(\.id),
            [
                "session:new-branch",
                "destination:home", "destination:todo", "destination:terminals", "destination:settings",
                "settings:general", "settings:accounts", "settings:sessions", "settings:themes",
                "settings:accessibility", "settings:customize", "settings:modelProviders", "settings:experimental",
                "settings:accounts:signin", "settings:accounts:github:connect",
                "help:privacy-policy", "help:third-party-notices",
            ]
        )
    }

    /// The standing rule reaching across machines: every session another Mac
    /// shares (the remote-session-control spec's §4 "Spotlight") is a row,
    /// named by the machine and workspace it lives in — and the machine
    /// itself is one too.
    func testRemoteSessionsAreSpotlightRowsNamedByMachineAndWorkspace() throws {
        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            remoteMachines: [PaletteRemoteMachine(deviceID: "d1", name: "Studio", workspaces: [
                PaletteRemoteWorkspace(id: "/a", name: "Alpha", panes: [.init(id: "s1", title: "migrate")])
            ])])
        let row = try XCTUnwrap(commands.first { $0.id == "remote:d1/s1" })
        XCTAssertEqual(row.title, "migrate")
        XCTAssertEqual(row.subtitle, "Studio · Alpha")
        XCTAssertEqual(row.symbol, "desktopcomputer.and.arrow.down")
        XCTAssertEqual(row.keywords, "remote Studio Alpha")
        XCTAssertEqual(row.action, .openRemoteSession(deviceID: "d1", sessionID: "s1", title: "migrate"))
        XCTAssertEqual(row.section, .sessions)
        XCTAssertEqual(row.detail, "remote")
        let machineRow = try XCTUnwrap(commands.first { $0.id == "remote-machine:d1" })
        XCTAssertEqual(machineRow.title, "Studio")
        XCTAssertEqual(machineRow.subtitle, "Remote machine")
        XCTAssertEqual(
            machineRow.action, .openRemoteSession(deviceID: "d1", sessionID: "s1", title: "migrate"),
            "the machine row opens its first session"
        )
    }

    /// Settings › Accounts' one button is a spotlight row of its own — the
    /// standing rule reaching *inside* a section — and it is whichever
    /// button the page is showing, never both.
    func testTheAccountButtonIsASpotlightRowInWhicheverStateItIsIn() {
        let whenSignedOut = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
        // By action, not by id prefix: the GitHub pair lives under
        // `settings:accounts:` too, and this test is about the other button.
        let signInRow = whenSignedOut.filter { $0.action == .signIn || $0.action == .signOut }
        XCTAssertEqual(signInRow.map(\.id), ["settings:accounts:signin"], "one row, not both halves of a toggle")
        XCTAssertEqual(signInRow.first?.title, "Sign in with Apple…")
        XCTAssertEqual(signInRow.first?.action, .signIn)
        XCTAssertEqual(signInRow.first?.symbol, "person.crop.circle.badge.checkmark")
        XCTAssertEqual(signInRow.first?.subtitle, "Settings › Accounts", "the row says where it lives")
        XCTAssertEqual(signInRow.first?.section, .places)

        let whenSignedIn = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, signedIn: true
        )
        let logOutRow = whenSignedIn.filter { $0.action == .signIn || $0.action == .signOut }
        XCTAssertEqual(logOutRow.map(\.id), ["settings:accounts:logout"])
        XCTAssertEqual(logOutRow.first?.title, "Log out")
        XCTAssertEqual(logOutRow.first?.action, .signOut)
        XCTAssertEqual(logOutRow.first?.symbol, "person.crop.circle.badge.xmark")
        XCTAssertEqual(logOutRow.first?.subtitle, "Settings › Accounts")
        XCTAssertEqual(logOutRow.first?.section, .places)

        // Found by what a user would type for it, which is rarely the words
        // the button happens to print.
        var model = CommandPaletteModel(commands: whenSignedIn)
        model.update(query: "log out")
        XCTAssertEqual(model.matches.first?.id, "settings:accounts:logout")
        model.update(query: "sign out")
        XCTAssertEqual(model.matches.first?.id, "settings:accounts:logout")

        model = CommandPaletteModel(commands: whenSignedOut)
        model.update(query: "sign in")
        XCTAssertEqual(model.matches.first?.id, "settings:accounts:signin")
        model.update(query: "account")
        XCTAssertTrue(
            model.matches.contains { $0.id == "settings:accounts:signin" },
            "and by 'account', beside the section it lives in"
        )
    }

    /// "Delete account…" is the third Accounts button, and unlike the pair
    /// above it has only one honest state: a row while signed in, and no row
    /// at all while signed out — there is no account to delete, so offering
    /// it would be offering a dead end.
    func testDeleteAccountIsASpotlightRowOnlyWhileSignedIn() {
        let whenSignedIn = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, signedIn: true
        )
        let deleteRows = whenSignedIn.filter { $0.action == .deleteAccount }
        XCTAssertEqual(deleteRows.map(\.id), ["settings:accounts:delete"])
        XCTAssertEqual(deleteRows.first?.title, "Delete account…")
        XCTAssertEqual(deleteRows.first?.subtitle, "Settings › Accounts", "the row says where it lives")
        XCTAssertEqual(deleteRows.first?.section, .places)
        XCTAssertEqual(deleteRows.first?.symbol, "person.crop.circle.badge.minus")

        let whenSignedOut = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
        XCTAssertFalse(
            whenSignedOut.contains { $0.action == .deleteAccount },
            "nothing to delete, so nothing to offer"
        )

        // Found by what someone reaching for it would type, none of which is
        // the word the button prints.
        var model = CommandPaletteModel(commands: whenSignedIn)
        // (Whole phrases only where the keyword order allows it — the
        // matcher wants the query's characters *in order*.)
        for query in ["delete account", "remove", "erase"] {
            model.update(query: query)
            XCTAssertEqual(model.matches.first?.id, "settings:accounts:delete", "typing \(query)")
        }
    }

    /// Settings › Accounts' GitHub button is a row of its own too, and the
    /// same rule applies: whichever half the account makes true, never both.
    func testTheGitHubButtonIsASpotlightRowInWhicheverStateItIsIn() {
        let whenDisconnected = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
        let connectRow = whenDisconnected.filter { $0.action == .connectGitHub || $0.action == .disconnectGitHub }
        XCTAssertEqual(connectRow.map(\.id), ["settings:accounts:github:connect"], "one row, not both halves")
        XCTAssertEqual(connectRow.first?.title, "Connect GitHub…")
        XCTAssertEqual(connectRow.first?.action, .connectGitHub)
        XCTAssertEqual(connectRow.first?.symbol, "link.badge.plus")
        XCTAssertEqual(connectRow.first?.subtitle, "Settings › Accounts", "the row says where it lives")
        XCTAssertEqual(connectRow.first?.section, .places)

        let whenConnected = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, githubConnected: true
        )
        let disconnectRow = whenConnected.filter { $0.action == .connectGitHub || $0.action == .disconnectGitHub }
        XCTAssertEqual(disconnectRow.map(\.id), ["settings:accounts:github:disconnect"])
        XCTAssertEqual(disconnectRow.first?.title, "Disconnect GitHub")
        XCTAssertEqual(disconnectRow.first?.action, .disconnectGitHub)
        XCTAssertEqual(disconnectRow.first?.symbol, "personalhotspot.slash")
        XCTAssertEqual(disconnectRow.first?.subtitle, "Settings › Accounts")
        XCTAssertEqual(disconnectRow.first?.section, .places)

        // Whichever state it is in, "github" is what a user types for it.
        var model = CommandPaletteModel(commands: whenDisconnected)
        model.update(query: "github")
        XCTAssertEqual(model.matches.first?.id, "settings:accounts:github:connect")
        model = CommandPaletteModel(commands: whenConnected)
        model.update(query: "github")
        XCTAssertEqual(model.matches.first?.id, "settings:accounts:github:disconnect")
        model.update(query: "disconnect")
        XCTAssertEqual(model.matches.first?.id, "settings:accounts:github:disconnect")
    }

    /// Every open workspace is a row — renamed as the sidebar shows it, found
    /// by its path too — that opens it and shows the Desk. A workspace with
    /// nothing running is findable all the same.
    func testEveryWorkspaceIsASpotlightRow() {
        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil,
            workspaces: [
                PaletteWorkspace(id: "alpha", label: "Alpha (renamed)", path: "/Users/me/code/alpha"),
                PaletteWorkspace(id: "beta", label: "beta", path: nil),
            ]
        )
        let rows = commands.filter { if case .selectWorkspace = $0.action { return true } else { return false } }
        XCTAssertEqual(rows.map(\.id), ["workspace:alpha", "workspace:beta"])
        XCTAssertEqual(rows.map(\.title), ["Alpha (renamed)", "beta"])
        XCTAssertEqual(rows.first?.keywords, "/Users/me/code/alpha")
        XCTAssertTrue(rows.allSatisfy { $0.section == .places && $0.subtitle == "Workspace" && $0.symbol == "folder" })
        XCTAssertEqual(rows.first?.action, .selectWorkspace(id: "alpha"))
        XCTAssertEqual(commands.first?.id, "workspace:alpha", "workspaces lead the places")
    }

    func testBranchSessionSetupIsASpotlightRow() {
        let commands = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
        let row = commands.first { $0.action == .startBranchSession }
        XCTAssertEqual(row?.id, "session:new-branch")
        XCTAssertEqual(row?.title, "New Branch Session…")
        XCTAssertEqual(row?.subtitle, "Sessions")
        XCTAssertEqual(row?.symbol, "arrow.triangle.branch")

        var model = CommandPaletteModel(commands: commands)
        model.update(query: "worktree")
        XCTAssertEqual(model.matches.first?.action, .startBranchSession)
    }

    /// Destructive/control verbs are gone: the spotlight finds things and
    /// setup entry points, it does not duplicate every menu command.
    func testTheSpotlightListsNoControlCommands() {
        let commands = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")], paneOrder: ["a"], focusedPaneID: "a"
        )
        XCTAssertFalse(commands.contains { $0.id.hasPrefix("new-") || ["close-pane", "interrupt", "reattach", "toggle-sidebar", "clear-notifications", "show-all-changes", "open-diff"].contains($0.id) })
        XCTAssertFalse(commands.contains { $0.detail?.hasPrefix("⌘") == true })
    }

    /// A browser pane's switch-to row says what it is rather than naming an
    /// engine it does not have.
    func testBrowserRowsSayBrowser() {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1"),
                pane("web", project: "alpha", group: "g1", kind: .browser),
            ],
            paneOrder: ["a", "web"],
            focusedPaneID: nil
        )

        XCTAssertEqual(commands.first { $0.id == "focus:web" }?.detail, "browser", "a browser is not an engine")
        XCTAssertEqual(commands.first { $0.id == "focus:a" }?.detail, "shell")
    }

    /// 6b-1 concern #3: a project row (here, the palette's "Switch to …"
    /// title) shows the id when no label is known, and the real label once
    /// `WorkspaceWindowController.projectLabels` has one — the same cache
    /// the outline and the inspector share, not a second lookup.
    func testSwitchRowsUseTheProjectLabelCacheWhenProvidedAndFallBackToTheID() {
        let noLabels = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: nil
        )
        XCTAssertEqual(noLabels.first { $0.id == "focus:a" }?.subtitle, "alpha · Session 1")

        let withLabels = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            projectLabels: ["alpha": "Alpha Project"]
        )
        XCTAssertEqual(withLabels.first { $0.id == "focus:a" }?.subtitle, "Alpha Project · Session 1")
    }

    func testNoSyntheticRowIsAppendedToWhatTheQueryFound() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "pane")

        XCTAssertEqual(
            model.matches.map(\.id),
            ["focus:a", "new-pane", "close-pane"],
            "what the query matched and nothing else — no 'Search brain for …' row"
        )
    }

    /// The canvas's two rows. "Enter" is per session and lives in the
    /// Terminals section beside the panes it contains — emitted before the
    /// pane rows so the section stays one consecutive run, which is the only
    /// thing the table's heading logic relies on.
    func testOneEnterRowPerSession() {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1", groupLabel: "Build"),
                pane("b", project: "alpha", group: "g2"),
                pane("c", project: "beta", group: "g3"),
            ],
            paneOrder: ["a", "b", "c"],
            focusedPaneID: nil
        )

        let enters = commands.filter { if case .enterSession = $0.action { return true } else { return false } }
        XCTAssertEqual(enters.map(\.id), ["enter:g1", "enter:g2", "enter:g3"])
        XCTAssertEqual(enters.map(\.title), [
            "Enter Build — alpha",
            "Enter Session 1 — alpha",
            "Enter Session 1 — beta",
        ])
        XCTAssertEqual(enters.map(\.detail), ["⌃1", "⌃2", "⌃1"], "the digit is per project, like ⌃1…⌃9 is")
        XCTAssertEqual(enters.map(\.section), [.terminals, .terminals, .terminals])
        XCTAssertEqual(enters.first?.action, .enterSession(group: "g1"))
    }

    // MARK: - filtering and selection

    func testFilteringIsCaseInsensitiveAndKeepsTheOrderOnAnEqualFit() {
        var model = CommandPaletteModel(commands: sample)

        model.update(query: "PANE")

        XCTAssertEqual(
            model.matches.map(\.id),
            ["focus:a", "new-pane", "close-pane"]
        )
    }

    func testAnEmptyOrWhitespaceQueryShowsNothingAtAll() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "   ")
        XCTAssertEqual(model.matches, [], "the bar and only the bar until something is typed")
        XCTAssertEqual(model.sectionTags, [nil], "no categories to tag, either")
    }

    func testEverySessionIsARowThatGoesToItsFirstPane() {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1", groupLabel: "Build"),
                pane("b", project: "alpha", group: "g1", groupLabel: "Build"),
                pane("c", project: "beta", group: "g2"),
            ],
            paneOrder: ["a", "b", "c"],
            focusedPaneID: nil,
            projectLabels: ["alpha": "Alpha Project"]
        )

        let sessions = commands.filter { $0.section == .sessions }
        XCTAssertEqual(sessions.map(\.title), ["Build", "Session 1"])
        XCTAssertEqual(sessions.map(\.subtitle), ["Alpha Project", "beta"])
        XCTAssertEqual(sessions.map(\.detail), ["2 panes", "1 pane"])
        XCTAssertEqual(sessions.first?.action, .focusPane(sessionID: "a"), "the session opens on its first pane")
    }

    /// Every Settings section is a spotlight row: found by its own name or
    /// by "settings", opening the page on itself.
    /// In the All view a category shows five rows, then a row that reveals
    /// ten more per press — "Show all" once no more than ten are left — in
    /// place; a new query folds it back, and a chosen tag shows the category
    /// whole.
    func testACategoryShowsFiveThenTenMorePerPressUntilShowAll() {
        let rows = (0..<27).map {
            PaletteCommand(id: "w\($0)", title: "Workspace \($0)", detail: nil, action: .noop, section: .places)
        } + [PaletteCommand(id: "s", title: "Workspace session", detail: nil, action: .noop, section: .sessions)]
        var model = CommandPaletteModel(commands: rows)
        model.update(query: "workspace")
        func places() -> [PaletteCommand] { model.matches.filter { $0.section == .places } }

        XCTAssertEqual(model.matches.first?.section, .sessions, "the short category is whole")
        XCTAssertEqual(places().count, 5 + 1)
        XCTAssertEqual(model.matches.last?.id, "show-more:Places")
        XCTAssertEqual(model.matches.last?.title, "Show 10 more")
        XCTAssertEqual(model.matches.last?.detail, "22 more")
        XCTAssertEqual(model.matches.last?.action, .showMore(.places))

        model.reveal(section: .places)
        XCTAssertEqual(places().count, 15 + 1)
        XCTAssertEqual(model.matches.last?.title, "Show 10 more")
        XCTAssertEqual(model.matches.last?.detail, "12 more")

        model.reveal(section: .places)
        XCTAssertEqual(places().count, 25 + 1)
        XCTAssertEqual(model.matches.last?.title, "Show all", "no more than a step left")
        XCTAssertEqual(model.matches.last?.detail, "2 more")

        model.reveal(section: .places)
        XCTAssertEqual(places().map(\.id), (0..<27).map { "w\($0)" }, "everything, and no row after")

        model.update(query: "workspac")
        XCTAssertEqual(places().count, 5 + 1, "typing folds it back")

        model.select(section: .places)
        XCTAssertEqual(model.matches.count, 27, "a tag shows the category whole")
    }

    func testTheSettingsSectionsAreSpotlightRows() {
        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil
        )
        let rows = commands.filter { if case .showSettingsSection = $0.action { return true } else { return false } }
        XCTAssertEqual(rows.map(\.title), SettingsSection.allCases.map(\.title))
        XCTAssertEqual(rows.map(\.symbol), SettingsSection.allCases.map(\.symbol))
        XCTAssertTrue(rows.allSatisfy { $0.subtitle == "Settings" && $0.keywords == "settings" })
        XCTAssertEqual(rows.first?.action, .showSettingsSection(.general))
    }

    /// The two Help pages are spotlight rows too (standing rule: everything
    /// navigable is findable), each under "Help" and reachable by typing
    /// "legal", "privacy" or "licence".
    func testTheLegalPagesAreSpotlightRows() {
        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil
        )
        let rows = commands.filter { if case .openLegal = $0.action { return true } else { return false } }
        XCTAssertEqual(rows.map(\.title), ["Privacy Policy", "Third-Party Notices"])
        XCTAssertTrue(rows.allSatisfy { $0.subtitle == "Help" && $0.keywords?.contains("legal") == true })
        XCTAssertEqual(rows.first?.action, .openLegal(.privacyPolicy))
    }

    func testTheSidebarsThreeDestinationsAreRowsWithTheirOwnIcons() {
        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil
        )
        let destinations = commands.filter {
            if case .showDestination = $0.action { return true } else { return false }
        }

        XCTAssertEqual(destinations.map(\.title), ["Home", "To Do List", "Desk", "Settings"])
        XCTAssertEqual(destinations.map(\.subtitle), [
            "under development",
            "under development",
            "no session",
            "under development",
        ])
        XCTAssertEqual(destinations.first?.action, .showDestination(.home))
        // Their own icons, not the Actions section's ⌘.
        XCTAssertEqual(destinations.map(\.icon), ["house", "checklist", "rectangle.split.2x2", "gearshape"])
    }

    func testATerminalsLiveTitleIsSearchableAndShownWhenTheNameHidesIt() {
        let named = CommandPaletteModel.build(
            panes: [{
                var pane = pane("a", project: "alpha", group: "g1", groupLabel: "Build", label: "claude")
                pane.title = "Fixing the parser"
                return pane
            }()],
            paneOrder: ["a"],
            focusedPaneID: nil
        )
        let row = named.first { $0.id == "focus:a" }
        XCTAssertEqual(row?.title, "claude")
        XCTAssertEqual(
            row?.subtitle, "alpha · Build · Fixing the parser",
            "a pane wearing a name of its own would otherwise hide what it is working on"
        )

        var model = CommandPaletteModel(commands: named)
        model.update(query: "parser")
        XCTAssertEqual(model.matches.first?.id, "focus:a", "and it is searchable either way")

        // A pane with no name of its own already *is* its title — no need to
        // print it twice.
        let unnamed = CommandPaletteModel.build(
            panes: [{
                var pane = pane("a", project: "alpha", group: "g1", groupLabel: "Build")
                pane.title = "Fixing the parser"
                return pane
            }()],
            paneOrder: ["a"],
            focusedPaneID: nil
        )
        XCTAssertEqual(unnamed.first { $0.id == "focus:a" }?.subtitle, "alpha · Build")
    }

    // MARK: - the tags

    func testTheTagsAreAllFollowedByEveryCategoryTheQueryFound() {
        var model = CommandPaletteModel(commands: CommandPaletteModel.build(
            panes: [
                pane("t", project: "spot", group: "g1", label: "spotlight terminal"),
                pane("w", project: "spot", group: "g1", label: "spotlight browser", kind: .browser),
            ],
            paneOrder: ["t", "w"],
            focusedPaneID: nil
        ))
        model.update(query: "spotlight")

        // "All" first, then only what was found — never a category with
        // nothing behind it.
        XCTAssertEqual(model.sectionTags, [nil, .terminals, .browsers])
    }

    func testChoosingATagNarrowsTheListButNeverTheTags() {
        var model = CommandPaletteModel(commands: CommandPaletteModel.build(
            panes: [
                pane("t", project: "spot", group: "g1", label: "spotlight terminal"),
                pane("w", project: "spot", group: "g1", label: "spotlight browser", kind: .browser),
            ],
            paneOrder: ["t", "w"],
            focusedPaneID: nil
        ))
        model.update(query: "spotlight")
        model.select(section: .browsers)

        XCTAssertEqual(model.matches.map(\.id), ["focus:w"])
        XCTAssertEqual(
            model.sectionTags, [nil, .terminals, .browsers],
            "the tags come from what the query found, so filtering can never hide the tag back to All"
        )
    }

    func testTabWrapsThroughTheTagsAndAQueryThatLosesOneFallsBackToAll() {
        var model = CommandPaletteModel(commands: CommandPaletteModel.build(
            panes: [pane("w", project: "spot", group: "g1", label: "spotlight browser", kind: .browser)],
            paneOrder: ["w"],
            focusedPaneID: nil
        ))
        model.update(query: "spotlight")
        XCTAssertEqual(model.sectionTags, [nil, .browsers])

        model.cycleSection(by: 1)
        XCTAssertEqual(model.selectedSection, .browsers)
        model.cycleSection(by: 1)
        XCTAssertNil(model.selectedSection, "⇥ wraps around a short, closed ring")
        model.cycleSection(by: -1)
        XCTAssertEqual(model.selectedSection, .browsers, "and ⇧⇥ goes back the other way")

        // Refine the query past the browser and the tag it stood on is gone —
        // holding it would filter the list to nothing with no way back.
        model.select(section: .browsers)
        model.update(query: "spotlight terminal that is not there")
        XCTAssertNil(model.selectedSection)
    }

    func testTypingReturnsTheHighlightToTheTop() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "a")
        model.moveSelection(by: 2)
        XCTAssertEqual(model.selectedIndex, 2)

        model.update(query: "new")

        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selected?.id, "new-pane")
    }

    func testSelectionClampsRatherThanWrapping() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "a")

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedIndex, 0, "up at the top stays at the top")

        model.moveSelection(by: 99)
        XCTAssertEqual(model.selectedIndex, model.matches.count - 1, "down at the bottom stays at the bottom")
    }

    func testAQueryThatMatchesNothingSaysSo() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "zzzz")

        XCTAssertEqual(model.matches.map(\.id), ["no-matches"], "the palette answers rather than refusing to grow")
        XCTAssertEqual(model.matches.first?.subtitle, "Nothing here matches \u{201C}zzzz\u{201D}")
        XCTAssertEqual(model.matches.first?.action, .noop)
        XCTAssertEqual(model.found, [], "and it is not a match — the tags stay empty")

        model.update(query: "")
        XCTAssertEqual(model.matches, [], "an empty field is still just the bar")
    }

    func testANarrowedTagWithNothingLeftSaysSoToo() {
        var model = CommandPaletteModel(commands: CommandPaletteModel.build(
            panes: [
                pane("t", project: "spot", group: "g1", label: "spotlight terminal"),
                pane("w", project: "spot", group: "g1", label: "spotlight browser", kind: .browser),
            ],
            paneOrder: ["t", "w"],
            focusedPaneID: nil
        ))
        model.update(query: "spotlight")
        model.select(section: .files)

        XCTAssertEqual(model.matches.map(\.id), ["no-matches"])
    }

    // MARK: - fuzzy matching

    func testTheQueryFindsAFileByScatteredCharacters() {
        var model = CommandPaletteModel(
            commands: [],
            files: ["macos/OmniAgent/CommandPalette.swift", "macos/OmniAgent/SessionHoverCard.swift"],
            filesRoot: URL(fileURLWithPath: "/repo")
        )

        model.update(query: "cmdpal")
        XCTAssertEqual(model.matches.map(\.title), ["CommandPalette.swift"], "in order, not next to each other")

        model.update(query: "shc")
        XCTAssertEqual(model.matches.map(\.title), ["SessionHoverCard.swift"], "the camelCase humps are word starts")

        model.update(query: "palcmd")
        XCTAssertEqual(model.matches.map(\.id), ["no-matches"], "out of order is not a match — fuzzy, not anagram")
    }

    func testAWholeWordOutranksTheSameLettersScattered() throws {
        // "Switch to alpha — Session 1 — pane" spells p-a-n-e out of
        // "al**p**h**a**… Sessio**n**… pan**e**" long before it reaches the
        // word. Scoring the run has to win, or the ranking is worse than the
        // substring matching it replaced.
        XCTAssertEqual(
            FuzzyMatch.score("pane", in: "Switch to alpha — Session 1 — pane"),
            FuzzyMatch.score("pane", in: "New terminal pane"),
            "the word is found in both, and scored the same way"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(FuzzyMatch.score("pane", in: "a pane")),
            try XCTUnwrap(FuzzyMatch.score("pane", in: "pxaxnxe")),
            "a run beats the same letters scattered"
        )

        var model = CommandPaletteModel(commands: [
            PaletteCommand(id: "scattered", title: "Pin all notes everywhere", detail: nil, action: .noop),
            PaletteCommand(id: "whole", title: "New terminal pane", detail: nil, action: .noop),
        ])
        model.update(query: "pane")

        XCTAssertEqual(model.matches.map(\.id), ["whole", "scattered"], "the better fit leads, whatever the list order was")
    }

    func testAScoreIsNilWhenTheCharactersAreNotAllThere() {
        XCTAssertNil(FuzzyMatch.score("zzz", in: "CommandPalette.swift"))
        XCTAssertNotNil(FuzzyMatch.score("cp", in: "CommandPalette.swift"))
    }

    // MARK: - the repository's files

    func testTheQueryFindsFilesTheEditorsHaveNotOpened() {
        var model = CommandPaletteModel(
            commands: sample,
            files: ["src/token.swift", "docs/DESIGN.md", "README.md"],
            filesRoot: URL(fileURLWithPath: "/repo")
        )
        model.update(query: "token")

        XCTAssertEqual(model.matches.map(\.id), ["file:/repo/src/token.swift"])
        XCTAssertEqual(model.matches.first?.title, "token.swift")
        XCTAssertEqual(model.matches.first?.subtitle, "src", "where it is, the way every other row says where it is")
        XCTAssertEqual(model.matches.first?.action, .openFile(path: "/repo/src/token.swift"))
        XCTAssertEqual(model.matches.first?.section, .files)

        model.update(query: "src/")
        XCTAssertEqual(model.matches.map(\.id), ["file:/repo/src/token.swift"], "the path matches as well as the name")
    }

    func testAFileAlreadyOpenInAnEditorIsOneRowNotTwo() {
        let open = CommandPaletteModel.build(
            panes: [
                pane(
                    "ed",
                    project: "alpha",
                    group: "g1",
                    kind: .editor,
                    editorTabs: [PersistedEditorTab(path: "/repo/src/token.swift", kind: "file", pinned: true)]
                )
            ],
            paneOrder: ["ed"],
            focusedPaneID: "ed"
        )
        var model = CommandPaletteModel(
            commands: open,
            files: ["src/token.swift"],
            filesRoot: URL(fileURLWithPath: "/repo")
        )
        model.update(query: "token")

        XCTAssertEqual(
            model.matches.filter { $0.section == .files }.map(\.id),
            ["file:/repo/src/token.swift"],
            "the open tab wins — going to it beats opening the file a second time"
        )
    }

    func testAFileSearchIsCappedAndSitsInItsOwnSection() {
        var model = CommandPaletteModel(
            commands: sample,
            files: (0..<40).map { "src/pane\($0).swift" },
            filesRoot: URL(fileURLWithPath: "/repo")
        )
        model.update(query: "pane")

        let files = model.matches.filter { $0.section == .files }
        XCTAssertEqual(files.count, CommandPaletteModel.sectionPreview + 1, "five and the Show more row in the All view")
        var narrowed = model
        narrowed.select(section: .files)
        XCTAssertEqual(narrowed.matches.count, CommandPaletteModel.fileMatchLimit, "a loose query is a query to narrow, not a directory listing")
        XCTAssertEqual(
            model.matches.map(\.section).reduce(into: [PaletteSection]()) { runs, section in
                if runs.last != section { runs.append(section) }
            },
            [.places, .files],
            "one run per section, in the palette's own section order — Files last"
        )
    }

    func testWithNoRepositoryThereAreNoFileRows() {
        var model = CommandPaletteModel(commands: sample, files: ["src/token.swift"], filesRoot: nil)
        model.update(query: "token")

        XCTAssertEqual(model.matches.map(\.id), ["no-matches"])
    }

    func testResetClearsTheQueryAndTheHighlightAlongWithTheList() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "new")
        model.moveSelection(by: 1)

        model.reset(commands: [sample[0]])

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.matches, [], "a cleared query shows nothing again")
        XCTAssertEqual(model.commands.map(\.id), ["focus:a"])
    }

    func testEveryOpenFileIsAGoToRowOncePerPathNoMatterHowManyPanesHoldIt() {
        let tabs = [
            PersistedEditorTab(path: "/repo/src/main.swift", kind: "file", pinned: true),
            PersistedEditorTab(path: "/repo/README.md", kind: "file", pinned: false),
        ]
        let commands = CommandPaletteModel.build(
            panes: [
                pane("e1", project: "alpha", group: "g1", kind: .editor, editorTabs: tabs),
                pane("e2", project: "alpha", group: "g1", kind: .editor, editorTabs: [tabs[0]]),
            ],
            paneOrder: ["e1", "e2"],
            focusedPaneID: nil
        )

        let files = commands.filter { if case .openFile = $0.action { return true } else { return false } }
        XCTAssertEqual(files.map(\.title), ["main.swift", "README.md"], "the filename is the row, Spotlight-style")
        XCTAssertEqual(files.map(\.subtitle), ["/repo/src", "/repo"], "the folder is the location line")
        XCTAssertEqual(files.first?.action, .openFile(path: "/repo/src/main.swift"))
    }

    func testAPaneIsFoundByWhatIsInItNotOnlyByItsTitle() {
        var model = CommandPaletteModel(
            commands: CommandPaletteModel.build(
                panes: [
                    pane("b", project: "alpha", group: "g1", label: "docs", kind: .browser, browserURL: "https://reactbits.dev/animations"),
                    pane("e", project: "alpha", group: "g1", kind: .editor, editorTabs: [
                        PersistedEditorTab(path: "/repo/src/parser.rs", kind: "file", pinned: true),
                    ]),
                ],
                paneOrder: ["b", "e"],
                focusedPaneID: nil
            )
        )

        model.update(query: "reactbits")
        XCTAssertEqual(model.matches.first?.action, .focusPane(sessionID: "b"), "the URL is searchable, unshown")

        model.update(query: "src/parser")
        XCTAssertEqual(model.matches.first?.action, .openFile(path: "/repo/src/parser.rs"), "so is a file's full path")
    }

    func testRowsComeOutInSectionOrderSoAGroupIsJustARunOfRows() {
        let commands = CommandPaletteModel.build(
                panes: [
                    pane("web", project: "alpha", group: "g1", kind: .browser),
                    pane("t1", project: "alpha", group: "g1"),
                    pane("ed", project: "alpha", group: "g1", kind: .editor, editorTabs: [
                        PersistedEditorTab(path: "/repo/main.swift", kind: "file", pinned: true),
                    ]),
                    pane("t2", project: "beta", group: "g2"),
                ],
                paneOrder: ["web", "t1", "ed", "t2"],
                focusedPaneID: nil
            )

        // Consecutive runs, never interleaved: the table can insert one
        // heading wherever the section changes and stop there.
        var runs: [PaletteSection] = []
        for command in commands where runs.last != command.section {
            runs.append(command.section)
        }
        XCTAssertEqual(runs, [.sessions, .terminals, .browsers, .places, .files])

        // Panes keep the outline's own order inside their section.
        XCTAssertEqual(
            commands.filter { $0.section == .terminals }.map(\.id),
            ["enter:g1", "enter:g2", "focus:t1", "focus:t2"]
        )
        // The editor pane sits with the files it holds.
        XCTAssertEqual(
            commands.filter { $0.section == .files }.map(\.id),
            ["focus:ed", "file:/repo/main.swift"]
        )
    }

    // MARK: - the panel

    func testThePanelRunsTheHighlightedRowAndClosesFirst() {
        let controller = CommandPaletteController()
        var ran: [PaletteAction] = []
        var openWhenRun: [Bool] = []
        controller.onRun = { action in
            ran.append(action)
            openWhenRun.append(!controller.isClosing)
        }
        controller.present(commands: sample, over: nil)
        controller.setQuery("switch")

        controller.runSelected()

        XCTAssertEqual(ran, [.focusPane(sessionID: "a")])
        XCTAssertEqual(
            openWhenRun,
            [false],
            "the action lands with the panel already dismissed — still on screen only for its fade"
        )
    }

    func testLosingTheKeyboardClosesTheSpotlight() {
        let controller = CommandPaletteController()
        controller.present(commands: sample, over: nil)
        XCTAssertFalse(controller.isClosing)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertTrue(controller.isClosing, "out of focus is out")
        XCTAssertNil(controller.window?.parent, "and it takes itself out of the workspace's window chain at once")
    }

    func testThePanelIsRebuiltFromScratchOnEveryOpen() {
        let controller = CommandPaletteController()
        controller.present(commands: sample, over: nil)
        controller.setQuery("pane")
        controller.moveSelection(by: 1)
        XCTAssertEqual(controller.model.selectedIndex, 1)

        controller.present(commands: [sample[1]], over: nil)

        XCTAssertEqual(controller.model.matches, [], "a fresh open is an empty query, and an empty query shows nothing")
        XCTAssertEqual(controller.model.selectedIndex, 0)
        controller.setQuery("pane")
        XCTAssertEqual(controller.model.matches.map(\.id), ["new-pane"])
        controller.dismiss()
    }

    func testThePanelIsJustTheBarUntilSomethingIsTyped() {
        let controller = CommandPaletteController()
        controller.present(commands: sample, over: nil)
        XCTAssertEqual(controller.window?.frame.height, CommandPaletteController.barHeight)

        controller.setQuery("pane")
        XCTAssertGreaterThan(
            controller.window?.frame.height ?? 0,
            CommandPaletteController.barHeight,
            "results unfold under the bar"
        )

        controller.setQuery("")
        XCTAssertEqual(controller.window?.frame.height, CommandPaletteController.barHeight, "and fold away again")
        XCTAssertFalse(
            controller.isClosing,
            "folding back to the bar is not closing — the bar and its cursor stay, the way Spotlight's do"
        )
        controller.dismiss()
    }

    /// "Resume remote session…" opens the spotlight with "remote" already
    /// typed. Making a text field the first responder selects all of it, so
    /// without collapsing that selection the very next keystroke would
    /// *replace* the pre-filled word instead of continuing it — the caret
    /// belongs at the end, the way it does when you type into Spotlight.
    func testAPreFilledQueryLeavesTheCaretAfterItRatherThanSelectingIt() throws {
        let controller = CommandPaletteController()
        controller.present(commands: sample, initialQuery: "remote", over: nil)
        defer { controller.dismiss() }

        XCTAssertEqual(controller.model.query, "remote", "the query is applied, not just displayed")
        let editor = try XCTUnwrap(
            controller.window?.firstResponder as? NSTextView,
            "the query field takes the keyboard on open"
        )
        XCTAssertEqual(editor.string, "remote")
        XCTAssertEqual(
            editor.selectedRange(), NSRange(location: 6, length: 0),
            "select-all would have the first keystroke wipe the pre-filled query"
        )
    }

    func testTheBarStaysPutWhileTheResultsGrowBeneathIt() {
        let controller = CommandPaletteController()
        controller.present(commands: sample, over: nil)
        controller.window?.setFrameOrigin(NSPoint(x: 100, y: 400))
        let top = controller.window?.frame.maxY ?? 0

        controller.setQuery("pane")

        XCTAssertEqual(controller.window?.frame.maxY ?? 0, top, accuracy: 0.5)
        controller.dismiss()
    }

    func testAClickOnTheScrimClosesTheSpotlight() throws {
        let scrim = SpotlightScrimWindow()
        var clicks = 0
        scrim.onClick = { clicks += 1 }
        let catcher = try XCTUnwrap(scrim.contentView)
        let click = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 5, y: 5),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: scrim.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        XCTAssertTrue(catcher.acceptsFirstMouse(for: click), "the scrim's window is never key, so the click must count anyway")
        catcher.mouseDown(with: click)

        XCTAssertEqual(clicks, 1)
    }

    // MARK: - the glass

    func testFocusModeGlassesTheWorkspaceAndTheSpotlightLeavesItAlone() throws {
        guard let sheet = WorkspaceGlass.sheet() else {
            throw XCTSkip("no Liquid Glass before macOS 26 — focus mode leaves the sheet out")
        }
        // The approval card's material exactly: `.regular`, untinted, full
        // strength. Anything softer stops reading as glass over the opaque
        // header bars the sheet also covers.
        XCTAssertEqual(sheet.alphaValue, 1, accuracy: 0.001)

        let focus = PaneZoomBackdropView()
        let focusGlass = try XCTUnwrap(focus.subviews.first)
        XCTAssertEqual(focusGlass.alphaValue, 1, accuracy: 0.001)

        // The spotlight's scrim carries no glass at all: it is a click-catcher
        // over an untouched workspace, and only the panel itself is a surface.
        let spotlight = SpotlightScrimWindow()
        let scrim = try XCTUnwrap(spotlight.contentView)
        XCTAssertTrue(scrim.subviews.isEmpty, "no sheet inside the scrim")
        XCTAssertNotEqual(String(describing: type(of: scrim)), String(describing: type(of: focusGlass)))
    }

    /// The fallback host is behind-window material, which only `maskImage`
    /// can shape — `layer.cornerRadius` leaves the blur and the window
    /// shadow square behind the rounded tint.
    func testTheFallbackGlassHostIsMaskedToItsCorners() throws {
        let host = CommandPaletteController.glassHost(NSView(), size: NSSize(width: 100, height: 50))
        guard let effect = host as? NSVisualEffectView else {
            throw XCTSkip("Liquid Glass shapes itself")
        }
        let mask = try XCTUnwrap(effect.maskImage, "behind-window material needs a mask to be rounded")
        XCTAssertEqual(mask.capInsets.top, CommandPaletteController.cornerRadius, "the corners keep their radius")
        XCTAssertEqual(mask.resizingMode, .stretch, "and only the middle stretches to the panel's height")
    }

    /// The standing "Spotlight finds everything" rule reaching the View
    /// menu's three remote-pane zoom items (the phase 2 spec's §1). Rows only
    /// while a remote pane has focus — a local pane is already 1:1 and has no
    /// scale to change, which is why `validateMenuItem` greys the menu items
    /// there too. Offering a row that does nothing is offering a dead end,
    /// the same call the Accounts rows make.
    func testTheRemoteZoomCommandsAreSpotlightRowsOnlyWithARemotePaneFocused() {
        let local = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil)
        XCTAssertTrue(
            local.filter { $0.id.hasPrefix("view:zoom") }.isEmpty,
            "a local pane has no scale to change"
        )

        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, remotePaneFocused: true
        )
        let rows = commands.filter { $0.id.hasPrefix("view:zoom") }
        XCTAssertEqual(rows.map(\.id), ["view:zoom:magnify", "view:zoom:shrink", "view:zoom:fit"])
        XCTAssertEqual(rows.map(\.title), ["Zoom In", "Zoom Out", "Actual Fit"])
        XCTAssertEqual(
            rows.map(\.action),
            [.zoomRemotePane(.magnify), .zoomRemotePane(.shrink), .zoomRemotePane(.fit)]
        )
        XCTAssertEqual(
            rows.map(\.symbol),
            ["plus.magnifyingglass", "minus.magnifyingglass", "1.magnifyingglass"]
        )
        XCTAssertEqual(rows.map(\.subtitle), ["View", "View", "View"], "the row says where it lives")
        XCTAssertEqual(rows.map(\.section), [.places, .places, .places])

        // Found by what a user would type for it, which is neither title.
        var model = CommandPaletteModel(commands: commands)
        model.update(query: "zoom remote")
        XCTAssertEqual(
            model.matches.filter { $0.id.hasPrefix("view:zoom") }.count, 3,
            "all three answer the words a user reaches for"
        )
    }

    // MARK: - fixtures

    private let sample: [PaletteCommand] = [
        PaletteCommand(id: "focus:a", title: "Switch to alpha — Session 1 — pane", detail: "shell", action: .focusPane(sessionID: "a")),
        // Rows to filter and order — what they *do* is not under test.
        PaletteCommand(id: "new-pane", title: "New terminal pane", detail: "⌘T", action: .noop),
        PaletteCommand(id: "close-pane", title: "Close pane shell", detail: "⌘W", action: .noop),
        PaletteCommand(id: "toggle-sidebar", title: "Toggle sidebar", detail: "⌃⌘S", action: .noop),
    ]

    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        label: String? = nil,
        kind: PaneKind = .terminal,
        browserURL: String = "",
        editorTabs: [PersistedEditorTab] = [],
        editorActiveIndex: Int = 0
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: .shell,
            cwd: "/",
            label: label,
            kind: kind,
            browserURL: browserURL,
            editorTabs: editorTabs,
            editorActiveIndex: editorActiveIndex
        )
    }
}
