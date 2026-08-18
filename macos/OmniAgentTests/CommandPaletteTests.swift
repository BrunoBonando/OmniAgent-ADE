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
        kind: PaneKind = .terminal
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: .shell,
            cwd: "/",
            label: label,
            kind: kind
        )
    }
}
