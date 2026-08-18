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

        let switches = commands.filter { if case .focusPane = $0.action { return true } else { return false } }
        XCTAssertEqual(switches.map(\.title), [
            "Switch to alpha — Build — migrate",
            "Switch to beta — Session 1 — Shell 1",
        ])
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
            ["focus:a", "new-pane", "new-browser", "new-editor", "new-session", "toggle-sidebar"]
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
                "focus:a", "new-pane", "new-browser", "new-editor", "new-session",
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
            ["new-pane", "new-browser", "new-editor", "new-session", "toggle-sidebar"]
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
        XCTAssertEqual(noLabels.first { $0.id == "focus:a" }?.title, "Switch to alpha — Session 1 — Shell 1")

        let withLabels = CommandPaletteModel.build(
            panes: [pane("a", project: "alpha", group: "g1")],
            paneOrder: ["a"],
            focusedPaneID: nil,
            unreadNotifications: 0,
            projectLabels: ["alpha": "Alpha Project"]
        )
        XCTAssertEqual(withLabels.first { $0.id == "focus:a" }?.title, "Switch to Alpha Project — Session 1 — Shell 1")
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

    // MARK: - brain search (Task 6a-2/6b-2)

    func testTheSearchBrainRowIsAbsentWithNoQueryAndAppearsOnceThereIsOne() {
        var model = CommandPaletteModel(commands: sample)
        XCTAssertNil(model.matches.first { $0.id == "search-brain" }, "no query, nothing to search for yet")

        model.update(query: "graph")
        let row = model.matches.first { $0.id == "search-brain" }
        XCTAssertEqual(row?.title, "Search brain for \u{201C}graph\u{201D}")
        XCTAssertEqual(row?.action, .searchBrain(query: "graph"))
        XCTAssertEqual(model.matches.last?.id, "search-brain", "always trails the real matches")
    }

    // MARK: - filtering and selection

    func testFilteringIsACaseInsensitiveSubstringThatPreservesOrder() {
        var model = CommandPaletteModel(commands: sample)

        model.update(query: "PANE")

        XCTAssertEqual(
            model.matches.map(\.id),
            ["focus:a", "new-pane", "close-pane", "search-brain"],
            "a non-empty query always trails with the search-brain row too"
        )
    }

    func testAnEmptyOrWhitespaceQueryShowsEverything() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "   ")
        XCTAssertEqual(model.matches.count, sample.count)
    }

    func testTypingReturnsTheHighlightToTheTop() {
        var model = CommandPaletteModel(commands: sample)
        model.moveSelection(by: 2)
        XCTAssertEqual(model.selectedIndex, 2)

        model.update(query: "new")

        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selected?.id, "new-pane")
    }

    func testSelectionClampsRatherThanWrapping() {
        var model = CommandPaletteModel(commands: sample)

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedIndex, 0, "up at the top stays at the top")

        model.moveSelection(by: 99)
        XCTAssertEqual(model.selectedIndex, sample.count - 1, "down at the bottom stays at the bottom")
    }

    func testAQueryThatMatchesNoActionStillOffersTheSearchBrainRow() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "zzzz")

        XCTAssertEqual(model.matches.map(\.id), ["search-brain"], "nothing to switch to, but always something to search for")
        XCTAssertEqual(model.selected?.action, .searchBrain(query: "zzzz"))
    }

    func testResetClearsTheQueryAndTheHighlightAlongWithTheList() {
        var model = CommandPaletteModel(commands: sample)
        model.update(query: "new")
        model.moveSelection(by: 1)

        model.reset(commands: [sample[0]])

        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.matches.map(\.id), ["focus:a"])
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
        XCTAssertEqual(files.map(\.title), ["Open main.swift", "Open README.md"])
        XCTAssertEqual(files.map(\.detail), ["src", "repo"])
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

        controller.runSelected()

        XCTAssertEqual(ran, [.focusPane(sessionID: "a")])
        XCTAssertEqual(openWhenRun, [false], "the action lands with focus already back in the workspace")
    }

    func testThePanelIsRebuiltFromScratchOnEveryOpen() {
        let controller = CommandPaletteController()
        controller.present(commands: sample, over: nil)
        controller.moveSelection(by: 2)
        XCTAssertEqual(controller.model.selectedIndex, 2)

        controller.present(commands: [sample[1]], over: nil)

        XCTAssertEqual(controller.model.matches.map(\.id), ["new-pane"])
        XCTAssertEqual(controller.model.selectedIndex, 0)
        controller.dismiss()
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
