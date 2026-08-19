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
            focusedPaneID: "a",
            unreadNotifications: 0
        )

        let switches = commands.filter { $0.id.hasPrefix("focus:") }
        XCTAssertEqual(switches.map(\.title), ["migrate", "Shell 1"])
        XCTAssertEqual(switches.map(\.subtitle), ["alpha · Build", "beta · Session 1"], "the location is its own line")
        XCTAssertEqual(switches.map(\.detail), ["shell", "shell"])
    }

    func testFocusedPaneCommandsAppearOnlyWhenSomethingIsFocused() {
        let unfocused = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0
        )
        XCTAssertEqual(
            unfocused.map(\.id),
            [
                "session:alpha/g1", "focus:a",
                "destination:dashboard", "destination:board", "destination:terminals",
                "new-pane", "new-browser", "new-editor", "new-session", "toggle-sidebar",
            ]
        )

        let focused = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: "a",
            unreadNotifications: 0
        )
        XCTAssertEqual(
            focused.map(\.id),
            [
                "session:alpha/g1", "focus:a",
                "destination:dashboard", "destination:board", "destination:terminals",
                "new-pane", "new-browser", "new-editor", "new-session",
                "close-pane", "interrupt", "reattach", "toggle-sidebar",
            ]
        )
        XCTAssertEqual(focused.first { $0.id == "close-pane" }?.action, .closePane(sessionID: "a"))
    }

    /// Interrupt and reattach are PTY verbs. A focused browser pane still
    /// offers close — the pane exists — but never the two session actions.
    func testAFocusedBrowserPaneOffersCloseButNoSessionActions() {
        let browserFocused = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1"),
                pane("web", project: "alpha", group: "g1", kind: .browser),
            ],
            paneOrder: ["a", "web"],
            focusedPaneID: "web",
            unreadNotifications: 0
        )
        XCTAssertNotNil(browserFocused.first { $0.id == "close-pane" })
        XCTAssertNil(browserFocused.first { $0.id == "interrupt" })
        XCTAssertNil(browserFocused.first { $0.id == "reattach" })

        let terminalFocused = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1"),
                pane("web", project: "alpha", group: "g1", kind: .browser),
            ],
            paneOrder: ["a", "web"],
            focusedPaneID: "a",
            unreadNotifications: 0
        )
        XCTAssertNotNil(terminalFocused.first { $0.id == "close-pane" })
        XCTAssertNotNil(terminalFocused.first { $0.id == "interrupt" })
        XCTAssertNotNil(terminalFocused.first { $0.id == "reattach" })
    }

    func testTheNewSessionRowNamesTheSessionItWouldCreate() {
        let named = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Session 1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0,
            nextSessionName: "Session 2"
        ).first { $0.id == "new-session" }
        XCTAssertEqual(named?.title, "New session — Session 2")
        XCTAssertEqual(named?.detail, "⌘N")
        XCTAssertEqual(named?.action, .newSession)

        let unnamed = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0
        ).first { $0.id == "new-session" }
        XCTAssertEqual(unnamed?.title, "New session", "no name to offer, no dangling dash")
    }

    func testTheClearNotificationsRowExistsOnlyWhenThereIsSomethingToClear() {
        XCTAssertNil(
            CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0)
                .first { $0.id == "clear-notifications" }
        )
        let row = CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 3)
            .first { $0.id == "clear-notifications" }
        XCTAssertEqual(row?.detail, "3 unread")
        XCTAssertEqual(row?.action, .clearNotifications)
    }

    func testAnEmptyWorkspaceStillOffersTheCommandsThatDoNotNeedAPane() {
        XCTAssertEqual(
            CommandPaletteModel.build(panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0)
                .map(\.id),
            [
                "destination:dashboard", "destination:board", "destination:terminals",
                "new-pane", "new-browser", "new-editor", "new-session", "toggle-sidebar",
            ]
        )
    }

    /// ⇧⌘T's palette twin sits beside "New terminal pane", and a browser
    /// pane's switch-to row says what it is rather than naming an engine it
    /// does not have.
    func testTheNewBrowserRowSitsBesideNewPaneAndBrowserRowsSayBrowser() {
        let commands = CommandPaletteModel.build(
            panes: [
                pane("a", project: "alpha", group: "g1"),
                pane("web", project: "alpha", group: "g1", kind: .browser),
            ],
            paneOrder: ["a", "web"],
            focusedPaneID: nil,
            unreadNotifications: 0
        )

        let row = commands.first { $0.id == "new-browser" }
        XCTAssertEqual(row?.title, "New browser pane")
        XCTAssertEqual(row?.detail, "⇧⌘T")
        XCTAssertEqual(row?.action, .newBrowserPane)

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
            focusedPaneID: nil,
            unreadNotifications: 0
        )
        XCTAssertEqual(noLabels.first { $0.id == "focus:a" }?.subtitle, "alpha · Session 1")

        let withLabels = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0,
            projectLabels: ["alpha": "Alpha Project"]
        )
        XCTAssertEqual(withLabels.first { $0.id == "focus:a" }?.subtitle, "Alpha Project · Session 1")
    }

    /// Task 12: the focused editor's active *file* tab can be diffed from the
    /// palette. Nothing else offers the row — there is no file to diff.
    func testTheOpenDiffRowFollowsTheFocusedEditorsActiveFileTab() {
        let rows = CommandPaletteModel.build(
            panes: [
                pane(
                    "ed",
                    project: "alpha",
                    group: "g1",
                    kind: .editor,
                    editorTabs: [PersistedEditorTab(path: "/w/src/token.swift", kind: "file", pinned: true)]
                )
            ],
            paneOrder: ["ed"],
            focusedPaneID: "ed",
            unreadNotifications: 0,
            hasGitRepo: true
        )

        let row = rows.first { $0.id == "open-diff" }
        XCTAssertEqual(row?.title, "Open diff for token.swift")
        XCTAssertEqual(row?.detail, "vs HEAD")
        XCTAssertEqual(row?.action, .openDiffForCurrentFile(path: "/w/src/token.swift"))
    }

    func testNothingElseOffersTheOpenDiffRow() {
        let terminal = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: "a",
            unreadNotifications: 0
        )
        XCTAssertNil(terminal.first { $0.id == "open-diff" }, "a terminal has no file to diff")

        let alreadyADiff = CommandPaletteModel.build(
            panes: [
                pane(
                    "ed",
                    project: "alpha",
                    group: "g1",
                    kind: .editor,
                    editorTabs: [PersistedEditorTab(path: "/w/src/token.swift", kind: "diff", pinned: true)]
                )
            ],
            paneOrder: ["ed"],
            focusedPaneID: "ed",
            unreadNotifications: 0
        )
        XCTAssertNil(alreadyADiff.first { $0.id == "open-diff" }, "the active tab is already the diff")

        let empty = CommandPaletteModel.build(
            panes: [pane("ed", project: "alpha", group: "g1", kind: .editor)],
            paneOrder: ["ed"],
            focusedPaneID: "ed",
            unreadNotifications: 0
        )
        XCTAssertNil(empty.first { $0.id == "open-diff" }, "an editor with no tabs has nothing to diff")

        let noRepo = CommandPaletteModel.build(
            panes: [
                pane(
                    "ed",
                    project: "alpha",
                    group: "g1",
                    kind: .editor,
                    editorTabs: [PersistedEditorTab(path: "/w/src/token.swift", kind: "file", pinned: true)]
                )
            ],
            paneOrder: ["ed"],
            focusedPaneID: "ed",
            unreadNotifications: 0
        )
        XCTAssertNil(
            noRepo.first { $0.id == "open-diff" },
            "outside a repository the row is absent, not a row that lands on an error"
        )
    }

    /// Task 13: "Show all changes" needs a repository to describe. The
    /// caller knows whether there is one; the model never runs git itself.
    func testShowAllChangesOnlyInARepo() {
        let without = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0
        )
        XCTAssertFalse(without.contains { $0.action == .showAllChanges })

        let with = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0, hasGitRepo: true
        )
        XCTAssertTrue(with.contains { $0.action == .showAllChanges })
        XCTAssertEqual(with.first { $0.action == .showAllChanges }?.id, "show-all-changes")
        XCTAssertEqual(with.first { $0.action == .showAllChanges }?.title, "Show all changes")
    }

    func testNoSyntheticRowIsAppendedToWhatTheQueryFound() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "graph")

        XCTAssertEqual(model.matches, [], "nothing matched, so the list is empty — no 'Search brain for …' row")
    }

    // MARK: - filtering and selection

    func testFilteringIsACaseInsensitiveSubstringThatPreservesOrder() {
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
            unreadNotifications: 0,
            projectLabels: ["alpha": "Alpha Project"]
        )

        let sessions = commands.filter { $0.section == .sessions }
        XCTAssertEqual(sessions.map(\.title), ["Build", "Session 1"])
        XCTAssertEqual(sessions.map(\.subtitle), ["Alpha Project", "beta"])
        XCTAssertEqual(sessions.map(\.detail), ["2 panes", "1 pane"])
        XCTAssertEqual(sessions.first?.action, .focusPane(sessionID: "a"), "the session opens on its first pane")
    }

    func testTheSidebarsThreeDestinationsAreRowsWithTheirOwnIcons() {
        let commands = CommandPaletteModel.build(
            panes: [], paneOrder: [], focusedPaneID: nil, unreadNotifications: 0
        )
        let destinations = commands.filter {
            if case .showDestination = $0.action { return true } else { return false }
        }

        XCTAssertEqual(destinations.map(\.title), ["Dashboard", "Board", "Desk"])
        XCTAssertEqual(destinations.map(\.subtitle), [
            "activity, tokens, approvals",
            "backlog, sprint, timeline",
            "no session",
        ])
        XCTAssertEqual(destinations.first?.action, .showDestination(.dashboard))
        // Their own icons, not the Actions section's ⌘.
        XCTAssertEqual(destinations.map(\.icon), ["chart.bar", "square.grid.2x2", "rectangle.split.2x2"])
    }

    func testATerminalsLiveTitleIsSearchableAndShownWhenTheNameHidesIt() {
        let named = CommandPaletteModel.build(
            panes: [{
                var pane = pane("a", project: "alpha", group: "g1", groupLabel: "Build", label: "claude")
                pane.title = "Fixing the parser"
                return pane
            }()],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0
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
            focusedPaneID: nil,
            unreadNotifications: 0
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
            focusedPaneID: nil,
            unreadNotifications: 0
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
            focusedPaneID: nil,
            unreadNotifications: 0
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
            focusedPaneID: nil,
            unreadNotifications: 0
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

    func testAQueryThatMatchesNothingShowsNothing() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "zzzz")

        XCTAssertEqual(model.matches, [])
        XCTAssertNil(model.selected)
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
            focusedPaneID: nil,
            unreadNotifications: 0
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
                focusedPaneID: nil,
                unreadNotifications: 0
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
                focusedPaneID: nil,
                unreadNotifications: 0
            )

        // Consecutive runs, never interleaved: the table can insert one
        // heading wherever the section changes and stop there.
        var runs: [PaletteSection] = []
        for command in commands where runs.last != command.section {
            runs.append(command.section)
        }
        XCTAssertEqual(runs, [.sessions, .terminals, .browsers, .files, .actions])

        // Panes keep the outline's own order inside their section.
        XCTAssertEqual(
            commands.filter { $0.section == .terminals }.map(\.id),
            ["focus:t1", "focus:t2"]
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
            openWhenRun.append(controller.window?.isVisible == true)
        }
        controller.present(commands: sample, over: nil)
        controller.setQuery("switch")

        controller.runSelected()

        XCTAssertEqual(ran, [.focusPane(sessionID: "a")])
        XCTAssertEqual(openWhenRun, [false], "the action lands with focus already back in the workspace")
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
        controller.dismiss()
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
        XCTAssertEqual(sheet.alphaValue, WorkspaceGlass.strength, accuracy: 0.001)
        XCTAssertLessThan(WorkspaceGlass.strength, 1, "short of full strength: the workspace stays recognisable")

        let focus = PaneZoomBackdropView()
        let focusGlass = try XCTUnwrap(focus.subviews.first)
        XCTAssertEqual(focusGlass.alphaValue, WorkspaceGlass.strength, accuracy: 0.001)

        // The spotlight's scrim carries no glass at all: it is a click-catcher
        // over an untouched workspace, and only the panel itself is a surface.
        let spotlight = SpotlightScrimWindow()
        let scrim = try XCTUnwrap(spotlight.contentView)
        XCTAssertTrue(scrim.subviews.isEmpty, "no sheet inside the scrim")
        XCTAssertNotEqual(String(describing: type(of: scrim)), String(describing: type(of: focusGlass)))
    }

    // MARK: - fixtures

    private let sample: [PaletteCommand] = [
        PaletteCommand(id: "focus:a", title: "Switch to alpha — Session 1 — pane", detail: "shell", action: .focusPane(sessionID: "a")),
        PaletteCommand(id: "new-pane", title: "New terminal pane", detail: "⌘T", action: .newPane),
        PaletteCommand(id: "close-pane", title: "Close pane shell", detail: "⌘W", action: .closePane(sessionID: "a")),
        PaletteCommand(id: "toggle-sidebar", title: "Toggle sidebar", detail: "⌃⌘S", action: .toggleSidebar),
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
